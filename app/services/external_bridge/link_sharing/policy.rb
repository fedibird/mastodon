# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # User-owned consent. This is not default privacy, posting style, or an
    # E3 route. Every mutation locks the policy row and bumps revision.
    class Policy
      VISIBILITIES = %w(public unlisted).freeze

      def self.grant!(user:, visibility:)
        new(user).grant!(visibility)
      end

      def self.revoke!(user:)
        new(user).revoke!
      end

      def self.change_visibility!(user:, visibility:)
        new(user).change_visibility!(visibility)
      end

      def initialize(user)
        @user = user
      end

      def grant!(visibility)
        visibility = normalize!(visibility)
        with_row do |policy|
          policy.visibility = visibility
          policy.enabled = true
          policy.consented_at ||= Time.current
          policy.revision = policy.revision.to_i + 1
        end
      end

      def revoke!
        with_row do |policy|
          raise Error, :consent_required if policy.new_record?

          policy.enabled = false
          policy.revision = policy.revision.to_i + 1
        end
      end

      def change_visibility!(visibility)
        visibility = normalize!(visibility)
        with_row do |policy|
          raise Error, :consent_required if policy.new_record?
          return policy if policy.visibility == visibility

          policy.visibility = visibility
          policy.revision = policy.revision.to_i + 1
        end
      end

      private

      def normalize!(visibility)
        raise Error, :not_owner if @user.nil? || @user.id.nil?

        value = visibility.to_s
        raise Error, :scope_rejected unless VISIBILITIES.include?(value)

        value
      end

      def with_row
        attempts = 0
        begin
          attempts += 1
          ApplicationRecord.transaction(requires_new: true) do
            policy = ExternalLinkSharePolicy.lock('FOR UPDATE').find_by(user_id: @user.id)
            policy ||= ExternalLinkSharePolicy.new(user_id: @user.id, revision: 0, enabled: false, visibility: 'unlisted')
            yield policy
            policy.save!
            policy
          end
        rescue ActiveRecord::RecordNotUnique
          retry if attempts < 2
          raise Error, :reference_conflict
        end
      end
    end
  end
end
