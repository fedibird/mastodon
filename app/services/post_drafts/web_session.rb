# frozen_string_literal: true

module PostDrafts
  # Adds the draft scopes to one WebUI session token. External application
  # tokens are never loaded or rewritten. A session created before the user
  # was admitted keeps `read write follow` until the next full page load
  # runs this, or until the user signs in again. Signing in while admitted
  # mints the scopes on the new session token directly.
  module WebSession
    READ_SCOPE = 'read:post_drafts'
    WRITE_SCOPE = 'write:post_drafts'
    Result = Struct.new(:enabled, :reason, keyword_init: true)

    class << self
      def prepare(session_activation)
        user = session_activation&.user
        return Result.new(enabled: false, reason: disabled_reason) unless Feature.permitted?(user)

        token = session_activation.access_token
        if token.nil? || token.revoked_at.present?
          return Result.new(enabled: false, reason: 'missing_scope')
        end

        return Result.new(enabled: true, reason: nil) if granted?(token)

        rotate!(session_activation, token)
        Result.new(enabled: true, reason: nil)
      end

      def granted?(token)
        token.scopes.exists?(READ_SCOPE) && token.scopes.exists?(WRITE_SCOPE)
      end

      def scope_list(base)
        names = Array(base).map(&:to_s)
        names << READ_SCOPE unless names.include?(READ_SCOPE)
        names << WRITE_SCOPE unless names.include?(WRITE_SCOPE)
        names
      end

      private

      def disabled_reason
        Feature.enabled? ? 'not_admitted' : 'disabled'
      end

      def rotate!(session_activation, token)
        SessionActivation.transaction do
          replacement = Doorkeeper::AccessToken.create!(
            application_id: token.application_id,
            resource_owner_id: token.resource_owner_id,
            scopes: scope_list(token.scopes).join(' '),
            expires_in: token.expires_in,
            use_refresh_token: false
          )
          session_activation.update!(access_token: replacement)
          token.revoke
          replacement
        end
      end
    end
  end
end
