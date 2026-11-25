# frozen_string_literal: true

module PostDrafts
  # Adds the draft scopes to one WebUI session token. External application
  # tokens are never loaded or rewritten. A session created before the user
  # was admitted keeps `read write follow` until the next full page load
  # runs this, or until the user signs in again. Signing in while admitted
  # mints the scopes on the new session token directly.
  #
  # Turning the flag off, or removing a tester, does not strip draft scopes
  # from a web token that already has them and does not revoke it. The WebUI
  # stops calling because the page flag is off. The post-draft API keeps
  # accepting any token that was explicitly granted the scopes, including
  # external OAuth tokens. That contract is unchanged.
  module WebSession
    READ_SCOPE = 'read:post_drafts'
    WRITE_SCOPE = 'write:post_drafts'
    Result = Struct.new(:enabled, :reason, keyword_init: true)

    class << self
      def prepare(session_activation)
        return Result.new(enabled: false, reason: 'missing_scope') if session_activation.nil?

        enabled = false
        reason = nil

        begin
          SessionActivation.transaction do
            locked = SessionActivation.lock.find_by(id: session_activation.id)

            if locked.nil?
              reason = 'missing_scope'
              next
            end

            unless Feature.permitted?(locked.user)
              reason = disabled_reason
              next
            end

            token = locked.access_token

            if token.nil? || token.revoked_at.present? || expired?(token)
              reason = 'missing_scope'
              next
            end

            if granted?(token)
              session_activation.access_token = token
              enabled = true
              next
            end

            session_activation.access_token = rotate!(locked, token)
            enabled = true
          end
        rescue ActiveRecord::ActiveRecordError
          session_activation.association(:access_token).reset
          return Result.new(enabled: false, reason: 'missing_scope')
        end

        return Result.new(enabled: true, reason: nil) if enabled

        Result.new(enabled: false, reason: reason || 'missing_scope')
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

      def expired?(token)
        return false if token.expires_in.blank?

        token.expired?
      end

      def rotate!(session_activation, token)
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
