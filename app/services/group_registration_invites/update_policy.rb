# frozen_string_literal: true

module GroupRegistrationInvites
  # Edits one group's copied invite policy. The site defaults and every
  # other group's row stay untouched. copied_at and the group identity are
  # left to the model, which refuses to change them.
  class UpdatePolicy
    Result = Struct.new(:code, :policy, keyword_init: true) do
      def success?
        code == :updated
      end
    end

    def self.call(policy:, actor_account:, attributes:)
      new(policy, actor_account, attributes).call
    end

    def initialize(policy, actor_account, attributes)
      @policy = policy
      @actor_account = actor_account
      @attributes = attributes.to_h.with_indifferent_access
    end

    def call
      return Result.new(code: :not_authorized, policy: @policy) unless GroupManagement.server_administrator?(@actor_account)
      return Result.new(code: :conflict, policy: @policy) if expected_version.nil?

      @policy.with_lock do
        if @policy.lock_version != expected_version
          @policy.reload
          return Result.new(code: :conflict, policy: @policy)
        end

        assign_limits
        return Result.new(code: :invalid, policy: @policy) unless @policy.valid?

        @policy.save!
      end
      Result.new(code: :updated, policy: @policy)
    rescue ActiveRecord::StaleObjectError
      Result.new(code: :conflict, policy: @policy.reload)
    rescue ActiveRecord::RecordInvalid
      Result.new(code: :invalid, policy: @policy)
    end

    private

    def expected_version
      Attributes.strict_integer(@attributes[:lock_version])
    end

    def assign_limits
      unlimited_uses = Attributes.boolean(@attributes[:per_link_unlimited_uses])
      indefinite = Attributes.boolean(@attributes[:per_link_indefinite])
      @policy.assign_attributes(
        issuance_enabled: Attributes.boolean(@attributes[:issuance_enabled]),
        shared_quota_unlimited: Attributes.boolean(@attributes[:shared_quota_unlimited]),
        shared_registration_quota: Attributes.strict_integer(@attributes[:shared_registration_quota]),
        per_link_unlimited_uses: unlimited_uses,
        per_link_max_uses: unlimited_uses ? nil : Attributes.strict_integer(@attributes[:per_link_max_uses]),
        per_link_indefinite: indefinite,
        per_link_lifetime_seconds: indefinite ? nil : Attributes.strict_integer(@attributes[:per_link_lifetime_seconds])
      )
    end
  end
end
