# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One-line key=value INFO records for the unsubscribe job. Only integers,
    # fixed event/state words, and exception class names are written. A feed
    # URL, title, item text, token, or exception message has no way in.
    module SubscriptionDeletionLog
      PREFIX = '[ExternalBridge::RSS::Deletion]'
      EVENTS = %w(
        accepted started batch completed failed enqueue_failed recovered skipped effects_pending
      ).freeze
      INT_FIELDS = %i(
        job_id deletion_id subscription_id user_id batch deleted total remaining attempt elapsed_ms pending
      ).freeze
      CLASS_FIELDS = %i(error_class).freeze
      CODE_FIELDS = %i(error_code state).freeze

      module_function

      def emit(event, fields = {})
        return unless EVENTS.include?(event.to_s)

        parts = fields.filter_map do |key, value|
          rendered = render(key.to_sym, value)
          "#{key}=#{rendered}" unless rendered.nil?
        end
        Rails.logger.info(([PREFIX, "event=#{event}"] + parts).join(' '))
      rescue StandardError
        nil
      end

      def render(key, value)
        if INT_FIELDS.include?(key)
          value.is_a?(Integer) && value >= 0 ? value : '-'
        elsif CLASS_FIELDS.include?(key)
          value.respond_to?(:name) && value.name.to_s.match?(/\A[A-Za-z0-9_:]+\z/) ? value.name : '-'
        elsif CODE_FIELDS.include?(key)
          value.to_s.match?(/\A[a-z0-9_]{1,40}\z/) ? value.to_s : '-'
        end
      end
    end
  end
end
