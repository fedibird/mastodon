# frozen_string_literal: true

module GroupRegistrationInvites
  # Writes the site defaults that the next approval copies. Rows that
  # already exist are not loaded or updated. group_creation_requests is
  # not one of these keys.
  class UpdateSiteDefaults
    Result = Struct.new(:code, :errors, keyword_init: true) do
      def success?
        code == :updated
      end
    end

    def self.fingerprint
      Digest::SHA256.hexdigest(JSON.generate(SiteDefaults.snapshot))
    end

    def self.call(actor_account:, attributes:, fingerprint:)
      new(actor_account, attributes, fingerprint).call
    end

    def initialize(actor_account, attributes, fingerprint)
      @actor_account = actor_account
      @attributes = attributes.to_h.with_indifferent_access
      @fingerprint = fingerprint.to_s
    end

    def call
      return Result.new(code: :not_authorized, errors: []) unless GroupManagement.server_administrator?(@actor_account)
      return Result.new(code: :conflict, errors: [:conflict]) unless current_fingerprint?

      values, errors = normalized_values
      return Result.new(code: :invalid, errors: errors) if errors.any?

      write!(values)
      Result.new(code: :updated, errors: [])
    end

    private

    def current_fingerprint?
      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(@fingerprint), Digest::SHA256.hexdigest(self.class.fingerprint))
    end

    def normalized_values
      errors = []
      unlimited_shared = Attributes.boolean(@attributes[:shared_quota_unlimited])
      unlimited_uses = Attributes.boolean(@attributes[:per_link_unlimited_uses])
      indefinite = Attributes.boolean(@attributes[:per_link_indefinite])
      quota = shared_quota(unlimited_shared, errors)
      max_uses = positive_integer(:per_link_max_uses, unlimited_uses, Setting.group_registration_invites_per_link_max_uses, errors)
      lifetime = positive_integer(:per_link_lifetime_seconds, indefinite, Setting.group_registration_invites_per_link_lifetime_seconds, errors)

      values = {
        issuance_enabled: Attributes.boolean(@attributes[:issuance_enabled]),
        shared_registration_quota: quota,
        shared_quota_unlimited: unlimited_shared,
        per_link_max_uses: max_uses,
        per_link_unlimited_uses: unlimited_uses,
        per_link_lifetime_seconds: lifetime,
        per_link_indefinite: indefinite,
      }
      [values, errors]
    end

    # Unlimited shared quota is stored as 0. SiteDefaults copies that integer
    # through, and the policy row rejects any other combination.
    def shared_quota(unlimited, errors)
      raw = @attributes[:shared_registration_quota]
      number = Attributes.strict_integer(raw)
      if unlimited
        if raw.to_s.strip.present? && number != 0
          errors << :shared_quota_unlimited_mismatch
          return number
        end

        return 0
      end

      errors << :shared_quota unless number.is_a?(Integer)
      number
    end

    # A number kept while the matching unlimited flag is on is the fallback
    # used if an administrator later turns that flag off. It still has to be
    # a positive integer so the next copy stays valid.
    def positive_integer(key, unlimited, fallback, errors)
      raw = @attributes[key]
      if unlimited && raw.to_s.strip.blank?
        number = Attributes.strict_integer(fallback)
        number = 1 unless number.is_a?(Integer) && number >= 1
        return number
      end

      number = Attributes.strict_integer(raw)
      unless number.is_a?(Integer) && number >= 1
        errors << key
        return number
      end

      number
    end

    def write!(values)
      Setting.transaction do
        Setting.group_registration_invites_enabled = values[:issuance_enabled]
        Setting.group_registration_invites_shared_quota = values[:shared_registration_quota]
        Setting.group_registration_invites_shared_quota_unlimited = values[:shared_quota_unlimited]
        Setting.group_registration_invites_per_link_max_uses = values[:per_link_max_uses]
        Setting.group_registration_invites_per_link_unlimited_uses = values[:per_link_unlimited_uses]
        Setting.group_registration_invites_per_link_lifetime_seconds = values[:per_link_lifetime_seconds]
        Setting.group_registration_invites_per_link_indefinite = values[:per_link_indefinite]
      end
    end
  end
end
