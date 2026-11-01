# frozen_string_literal: true

module GroupRegistrationInvites
  # Writes the site defaults that the next approval copies. Existing
  # GroupRegistrationInvitePolicy rows are not loaded or updated.
  # group_creation_requests is not one of these keys.
  #
  # Setting.[]= writes Rails.cache before the surrounding transaction
  # commits. Production cache is Redis, shared by every process, so that
  # would publish a value that might still roll back. This writer saves
  # the row only. RailsSettings republishes the cache in after_commit,
  # and publish_cache below covers a test transaction that never commits
  # the outer savepoint. A failure deletes the keys so the next read
  # reloads the committed row. The advisory lock does not include console
  # writes or other admin setting screens.
  class UpdateSiteDefaults
    KEYS = %w(
      group_registration_invites_enabled
      group_registration_invites_shared_quota
      group_registration_invites_shared_quota_unlimited
      group_registration_invites_per_link_max_uses
      group_registration_invites_per_link_unlimited_uses
      group_registration_invites_per_link_lifetime_seconds
      group_registration_invites_per_link_indefinite
    ).freeze

    # Serializes writers. The settings table has no single parent row, so a
    # transaction advisory lock is the critical section for compare-and-set.
    LOCK_KEY = 6_740_002_002

    Result = Struct.new(:code, :errors, keyword_init: true) do
      def success?
        code == :updated
      end
    end

    class Conflict < StandardError; end

    class Invalid < StandardError
      attr_reader :error_codes

      def initialize(error_codes)
        @error_codes = error_codes
        super('invalid group invite defaults')
      end
    end

    def self.fingerprint
      fingerprint_for(read_stored)
    end

    def self.fingerprint_for(stored)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(stored)))
    end

    def self.call(actor_account:, attributes:, fingerprint:)
      new(actor_account, attributes, fingerprint).call
    end

    def self.read_stored
      rows = Setting.unscoped.where(thing_type: nil, thing_id: nil, var: KEYS).index_by(&:var)
      KEYS.index_with { |key| rows[key] ? rows[key].value : Setting[key] }
    end

    def self.canonicalize(stored)
      values = stored.to_h.stringify_keys
      {
        'group_registration_invites_enabled' => Attributes.boolean(values['group_registration_invites_enabled']),
        'group_registration_invites_shared_quota' => Attributes.strict_integer(values['group_registration_invites_shared_quota']),
        'group_registration_invites_shared_quota_unlimited' => Attributes.boolean(values['group_registration_invites_shared_quota_unlimited']),
        'group_registration_invites_per_link_max_uses' => Attributes.strict_integer(values['group_registration_invites_per_link_max_uses']),
        'group_registration_invites_per_link_unlimited_uses' => Attributes.boolean(values['group_registration_invites_per_link_unlimited_uses']),
        'group_registration_invites_per_link_lifetime_seconds' => Attributes.strict_integer(values['group_registration_invites_per_link_lifetime_seconds']),
        'group_registration_invites_per_link_indefinite' => Attributes.boolean(values['group_registration_invites_per_link_indefinite']),
      }
    end

    def initialize(actor_account, attributes, fingerprint)
      @actor_account = actor_account
      @attributes = attributes.to_h.with_indifferent_access
      @fingerprint = fingerprint.to_s
    end

    def call
      return Result.new(code: :not_authorized, errors: []) unless GroupManagement.server_administrator?(@actor_account)

      outcome = nil
      published = nil
      Setting.transaction do
        lock_writers!
        current = locked_stored
        raise Conflict unless fingerprints_match?(current)

        values, errors = normalized_values(current)
        raise Invalid, errors if errors.any?

        before = self.class.canonicalize(current)
        if before == values
          outcome = Result.new(code: :updated, errors: [])
          next
        end

        write!(values)
        audit!(before, values)
        published = values
        outcome = Result.new(code: :updated, errors: [])
      end
      publish_cache(published) if published
      outcome
    rescue Conflict
      Result.new(code: :conflict, errors: [:conflict])
    rescue Invalid => e
      Result.new(code: :invalid, errors: e.error_codes)
    rescue GroupAdministration::Audit::Error
      expire_cache
      Result.new(code: :audit_failed, errors: [:audit_failed])
    rescue StandardError
      expire_cache
      raise
    end

    private

    def lock_writers!
      Setting.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
    end

    def locked_stored
      rows = Setting.unscoped.where(thing_type: nil, thing_id: nil, var: KEYS).lock.index_by(&:var)
      KEYS.index_with { |key| rows[key] ? rows[key].value : Setting[key] }
    end

    def fingerprints_match?(stored)
      expected = self.class.fingerprint_for(stored)
      return false unless @fingerprint.bytesize == expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(@fingerprint, expected)
    end

    def normalized_values(current)
      errors = []
      canonical = self.class.canonicalize(current)
      unlimited_shared = Attributes.boolean(@attributes[:shared_quota_unlimited])
      unlimited_uses = Attributes.boolean(@attributes[:per_link_unlimited_uses])
      indefinite = Attributes.boolean(@attributes[:per_link_indefinite])
      quota = shared_quota(unlimited_shared, errors)
      max_uses = positive_integer(:per_link_max_uses, unlimited_uses, canonical['group_registration_invites_per_link_max_uses'], errors)
      lifetime = positive_integer(:per_link_lifetime_seconds, indefinite, canonical['group_registration_invites_per_link_lifetime_seconds'], errors)
      values = {
        'group_registration_invites_enabled' => Attributes.boolean(@attributes[:issuance_enabled]),
        'group_registration_invites_shared_quota' => quota,
        'group_registration_invites_shared_quota_unlimited' => unlimited_shared,
        'group_registration_invites_per_link_max_uses' => max_uses,
        'group_registration_invites_per_link_unlimited_uses' => unlimited_uses,
        'group_registration_invites_per_link_lifetime_seconds' => lifetime,
        'group_registration_invites_per_link_indefinite' => indefinite,
      }
      [values, errors]
    end

    # Zero is allowed. Negatives and values above the PostgreSQL integer
    # column are refused. Unlimited shared quota is stored as 0 because the
    # approval copy keeps that integer.
    def shared_quota(unlimited, errors)
      number = Attributes.strict_integer(@attributes[:shared_registration_quota])
      if unlimited
        if @attributes[:shared_registration_quota].to_s.strip.present? && number != 0
          errors << :shared_quota_unlimited_mismatch
        end
        return 0 if errors.empty?

        return number
      end

      errors << :shared_quota unless acceptable_quota?(number)
      number
    end

    def acceptable_quota?(number)
      number.is_a?(Integer) && number >= 0 && number <= Attributes::INTEGER_MAX
    end

    def positive_integer(key, unlimited, fallback, errors)
      raw = @attributes[key]
      if unlimited && raw.to_s.strip.blank?
        number = Attributes.strict_integer(fallback)
        number = 1 unless number.is_a?(Integer) && number >= 1 && number <= Attributes::INTEGER_MAX
        return number
      end

      number = Attributes.strict_integer(raw)
      unless number.is_a?(Integer) && number >= 1 && number <= Attributes::INTEGER_MAX
        errors << key
      end
      number
    end

    # save! does not touch Rails.cache. Setting.[]= would.
    def write!(values)
      values.each do |key, value|
        record = Setting.unscoped.where(thing_type: nil, thing_id: nil).lock.find_by(var: key)
        record ||= Setting.new(var: key)
        record.value = value
        record.save!
      end
    end

    def publish_cache(values)
      values.each do |key, value|
        Rails.cache.write(Setting.cache_key(key, nil), value)
      end
    end

    def audit!(before, after)
      setting = Setting.unscoped.find_by!(thing_type: nil, thing_id: nil, var: 'group_registration_invites_enabled')
      GroupAdministration::Audit.record!(
        account: @actor_account,
        action: :update_group_invite_defaults,
        target: setting,
        changes: { 'before' => before, 'after' => after }
      )
    end

    def expire_cache
      KEYS.each { |key| Rails.cache.delete(Setting.cache_key(key, nil)) }
    end
  end
end
