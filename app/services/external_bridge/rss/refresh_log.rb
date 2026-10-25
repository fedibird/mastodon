# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One-line, key=value INFO records for the RSS scheduler and source refresh.
    #
    # The helper is deliberately narrow. Field names come from a fixed schema and
    # an unknown field is dropped. Every field has a type, and a value that does
    # not fit it is written as "-":
    #
    #   int          a non-negative Integer (or, for ids, a string of digits)
    #   enum         one of a fixed list
    #   error_code   a fixed RSS error code or http_NNN
    #   exception    an Exception class, written as its constant name
    #   id_list      an Array of Integers, capped at MAX_IDS
    #
    # A free-form string (URL, header, title, GUID, user detail, exception
    # message, or any other alphanumeric secret) therefore has no way to reach the
    # log. A logging failure never reaches the caller.
    module RefreshLog
      PREFIX = '[ExternalBridge::RSS]'
      MAX_IDS = 20
      MAX_DIGITS = 19

      EVENTS = %w(scheduler refresh icon).freeze

      OUTCOMES = %w(
        feature_disabled
        no_testers
        no_due_sources
        queued
        not_enqueued
        scheduler_error
        fetched
        not_modified
        http_error
        fetch_failed
        parse_failed
        import_failed
        refresh_failed
        skipped_not_due
        skipped_lock_busy
        skipped_source_missing
        skipped_feature_disabled
        skipped_no_permitted_subscriptions
        skipped_inactive_subscription
        unexpected_error
        icon_stored
        icon_replaced
        icon_unchanged
        icon_not_modified
        icon_not_found
        icon_failed
        skipped_no_subscriptions
      ).freeze

      ERROR_CODES = %w(
        authenticated_source_rejected
        fetch_failed
        import_failed
        malformed_feed
        oversized_feed
        private_address
        rate_limited
        unsupported_url
        icon_bad_content_type
        icon_empty
        icon_unrecognized_image
        icon_type_mismatch
        icon_dimensions
        icon_too_small
        icon_unsuitable_shape
        icon_storage_failed
        icon_no_candidate
      ).freeze

      HTTP_CODE = /\Ahttp_[1-5]\d\d\z/
      CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

      ID_FIELDS = %i(source_id subscription_id).freeze
      COUNTER_FIELDS = %i(
        selected enqueued rejected accounted offered offer_failed items cached_items
        projected_ok projected_failed projected_skipped failures http_status elapsed_ms
        candidates attempts
      ).freeze

      module_function

      def emit(event, fields)
        Rails.logger.info(line(event, fields))
        nil
      rescue StandardError
        nil
      end

      def line(event, fields)
        pairs = []
        fields.each do |key, value|
          next if value.nil?

          rendered = render(key.to_sym, value)
          pairs << rendered unless rendered.nil?
        end
        ids = fields[:source_ids]
        pairs.concat(truncated_pair(ids)) if ids.is_a?(Array) && ids.size > MAX_IDS
        "#{PREFIX} event=#{enum(EVENTS, event)} #{pairs.join(' ')}".strip
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((now - started) * 1000).round
      end

      def code(value)
        text = value.to_s
        ERROR_CODES.include?(text) || text.match?(HTTP_CODE) ? text : 'unknown'
      end

      # Returns "key=value" or nil when the key is not in the schema.
      def render(key, value)
        text =
          case key
          when :outcome then enum(OUTCOMES, value)
          when :error_code then code(value)
          when :error_class then exception(value)
          when :source_ids then id_list(value)
          when *ID_FIELDS then id(value)
          when *COUNTER_FIELDS then counter(value)
          else return nil
          end
        "#{key}=#{text}"
      end

      def enum(allowed, value)
        text = value.to_s
        allowed.include?(text) ? text : 'unknown'
      end

      def counter(value)
        value.is_a?(Integer) && value >= 0 && value.to_s.size <= MAX_DIGITS ? value.to_s : '-'
      end

      def id(value)
        return '-' if value == '-'
        return counter(value) if value.is_a?(Integer)

        value.is_a?(String) && value.match?(/\A\d{1,#{MAX_DIGITS}}\z/) ? value : '-'
      end

      def id_list(value)
        return '-' unless value.is_a?(Array)

        ids = value.first(MAX_IDS).map { |entry| id(entry) }.reject { |entry| entry == '-' }
        ids.empty? ? '-' : ids.join(',')
      end

      def truncated_pair(ids)
        ["source_ids_truncated=#{ids.size - MAX_IDS}"]
      end

      def exception(value)
        name = value.is_a?(Class) && value <= Exception ? value.name.to_s : ''
        name.size <= 120 && name.match?(CLASS_NAME) ? name : 'unknown'
      end
    end
  end
end
