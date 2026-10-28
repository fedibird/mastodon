# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Saves the owner's display choices and queues a rewrite of the statuses
    # already imported for this subscription. The request returns after the
    # row is stored. It does not walk the projection history.
    class PresentationUpdate
      OMIT = :omit

      # rubocop:disable Metrics/ParameterLists
      def call(user:, subscription_id:, media_sensitive: OMIT, cw_enabled: OMIT, language_mode: OMIT, language: OMIT)
        # rubocop:enable Metrics/ParameterLists
        attrs = flags(media_sensitive, cw_enabled).merge(language_change(language_mode, language))
        raise Error, :invalid_presentation if attrs.empty?

        subscription = nil
        ExternalSubscription.transaction do
          subscription = ExternalSubscription.lock.find_by(id: subscription_id, user_id: user.id)
          raise Error, :not_found if subscription.nil?
          raise Error, :subscription_deleting if subscription.deleting?

          unless unchanged?(subscription, attrs)
            now = Time.current
            token = SecureRandom.hex(16)
            sql = "#{attrs.keys.map { |key| "#{key} = ?" }.join(', ')}, presentation_revision = presentation_revision + 1, presentation_error = NULL, presentation_lease_token = ?, presentation_lease_until = ?, updated_at = ?"
            updated = ExternalSubscription.where(id: subscription.id).where.not(state: ExternalSubscription::DELETING).update_all(
              [sql, *attrs.values, token, now + PresentationReconcileWorker::LEASE, now]
            )
            raise Error, ExternalSubscription.exists?(subscription.id) ? :subscription_deleting : :not_found if updated.zero?

            enqueue(subscription.id, token)
          end
        end
        subscription.reload
      end

      private

      def flags(media_sensitive, cw_enabled)
        attrs = {}
        attrs[:media_sensitive] = cast(media_sensitive) unless media_sensitive == OMIT
        attrs[:cw_enabled] = cast(cw_enabled) unless cw_enabled == OMIT
        attrs
      end

      # A missing mode and code leaves the saved choice alone. An explicit
      # unspecified is a real change. A code is stored only for fixed mode.
      def language_change(mode, language)
        return {} if mode == OMIT && language == OMIT
        raise Error, :invalid_presentation unless mode.is_a?(String) && ArticleLanguage::MODES.include?(mode)

        case mode
        when 'unspecified', 'auto'
          raise Error, :invalid_presentation if language_code_sent?(language)

          { language_mode: mode, language: nil }
        when 'fixed'
          code = ArticleLanguage.canonical(language)
          raise Error, :invalid_presentation if code.nil?

          { language_mode: 'fixed', language: code }
        end
      end

      def language_code_sent?(language)
        return false if language == OMIT || language.nil?

        true
      end

      def unchanged?(subscription, attrs)
        attrs.all? { |key, value| subscription.public_send(key) == value }
      end

      def cast(value)
        return true if [true, 1, '1', 'true', 'TRUE'].include?(value)
        return false if [false, 0, '0', 'false', 'FALSE'].include?(value)

        raise Error, :invalid_presentation
      end

      # The generation is read again at enqueue time. A newer save replaces the
      # token, and this callback then queues nothing: the newer save queues
      # the token that still owns the row.
      def enqueue(subscription_id, token)
        Streaming::AfterOuterCommit.run do
          current = ExternalSubscription.find_by(id: subscription_id)
          if current && !current.deleting? && current.presentation_lease_token == token && current.presentation_revision.to_i > current.presentation_applied_revision.to_i
            PresentationReconcileWorker.perform_async(current.id, current.presentation_revision.to_i, 0, token)
          end
        rescue Redis::BaseError => e
          Rails.logger.info("[ExternalBridge::RSS] presentation enqueue error=#{e.class}")
        end
      end
    end
  end
end
