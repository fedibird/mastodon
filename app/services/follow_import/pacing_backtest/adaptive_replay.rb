# frozen_string_literal: true

# In-memory AIMD replay using production AdaptiveRemoteObservation and
# AdaptiveRemoteController. No Redis.
module FollowImport
  class PacingBacktest
    class AdaptiveReplay
      ERROR_CLASSES = {
        'HTTP::TimeoutError' => HTTP::TimeoutError,
        'HTTP::ConnectionError' => HTTP::ConnectionError,
        'OpenSSL::SSL::SSLError' => OpenSSL::SSL::SSLError,
      }.freeze

      def initialize(rows, candidate, bucket_seconds)
        @rows = rows
        @candidate = candidate
        @bucket_seconds = bucket_seconds
        @fixed = candidate.fixed_profile
        @adaptive = candidate.adaptive_profile
      end

      def to_h
        return unavailable unless @adaptive

        dest_states = {}
        origin_states = {}
        dest_stats = LayerStats.new(@adaptive.destination, @fixed.destination_per_tick_cap)
        origin_stats = LayerStats.new(@adaptive.origin, @fixed.origin_per_tick_cap)
        first_pressure = Pressure.new
        all_pressure = Pressure.new

        ordered = @rows.select(&:timed?).sort_by { |row| [row.event_time.to_f, row.row_number] }
        ordered.each do |row|
          observation = classify(row)
          dest_view = prepare_view(dest_states, row.destination_domain, :destination, row.event_time)
          origin_view = prepare_view(origin_states, row.endpoint_origin, :origin, row.event_time)

          views = { destination: dest_view, origin: origin_view }
          all_pressure.observe(row, views, @bucket_seconds)
          first_pressure.observe(row, views, @bucket_seconds) if row.first_attempt?

          apply_layer(
            'store' => dest_states,
            'stats' => dest_stats,
            'key' => row.destination_domain,
            'layer' => :destination,
            'view' => dest_view,
            'observation' => observation,
            'now' => row.event_time
          )
          apply_layer(
            'store' => origin_states,
            'stats' => origin_stats,
            'key' => row.endpoint_origin,
            'layer' => :origin,
            'view' => origin_view,
            'observation' => observation,
            'now' => row.event_time
          )
        end

        {
          'available' => true,
          'adaptive_profile_version' => @adaptive.version,
          'adaptive_profile_digest' => @adaptive.digest,
          'first_attempt_pressure' => first_pressure.to_h,
          'all_attempt_pressure' => all_pressure.to_h,
          'destination' => dest_stats.to_h(dest_states),
          'origin' => origin_stats.to_h(origin_states),
          'note' => 'constraint exposure against the current adaptive cap before each event is applied; not a causal prevention estimate',
        }
      end

      private

      def unavailable
        {
          'available' => false,
          'note' => 'adaptive profile omitted; fixed-only analysis',
        }
      end

      def classify(row)
        FollowImport::AdaptiveRemoteObservation.classify(
          http_status: row.http_status,
          error: error_from(row.error_class),
          request_started_at: row.request_started_at
        )
      end

      def error_from(name)
        klass = ERROR_CLASSES[name.to_s]
        return if klass.nil?

        klass.new
      end

      def prepare_view(store, key, layer, now)
        return if skip_key?(key, layer)

        params = params_for(layer)
        ceiling = ceiling_for(layer)
        view = store[key]
        if view.nil?
          view = FollowImport::AdaptiveRemoteController.initial_view(
            params,
            now: now,
            adaptive_digest: @adaptive.digest,
            fixed_digest: @fixed.digest,
            ceiling: ceiling
          )
          store[key] = view
          return view
        end

        payload = {
          'schema_version' => view.schema_version,
          'current_cap' => view.current_cap,
          'success_credit' => view.success_credit,
          'observed_at' => view.observed_at,
          'adaptive_profile_digest' => view.adaptive_profile_digest,
          'fixed_profile_digest' => view.fixed_profile_digest,
        }
        refreshed = FollowImport::AdaptiveRemoteController.view_from_payload(
          payload,
          params: params,
          now: now,
          stale_after: @adaptive.stale_after_seconds,
          adaptive_digest: @adaptive.digest,
          fixed_digest: @fixed.digest,
          ceiling: ceiling
        )
        store[key] = refreshed
        refreshed
      end

      def apply_layer(attrs)
        store = attrs['store']
        stats = attrs['stats']
        key = attrs['key']
        layer = attrs['layer']
        view = attrs['view']
        observation = attrs['observation']
        now = attrs['now']
        return if view.nil? || skip_key?(key, layer)

        event = observation.event
        stats.observe_before(view, event)
        unless FollowImport::AdaptiveRemoteObservation.mutating?(event)
          stats.observe_neutral
          return
        end

        after = FollowImport::AdaptiveRemoteController.apply(
          view,
          event,
          params_for(layer),
          ceiling: ceiling_for(layer),
          now: now,
          adaptive_digest: @adaptive.digest,
          fixed_digest: @fixed.digest
        )
        stats.observe_after(view, after, event)
        store[key] = after
      end

      def skip_key?(key, layer)
        return true if key.blank?
        return local_destination?(key) if layer == :destination

        false
      end

      def local_destination?(domain)
        TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
      rescue StandardError
        false
      end

      def params_for(layer)
        layer == :origin ? @adaptive.origin : @adaptive.destination
      end

      def ceiling_for(layer)
        layer == :origin ? @fixed.origin_per_tick_cap : @fixed.destination_per_tick_cap
      end

      class Pressure
        def initialize
          @above_destination = 0
          @above_origin = 0
          @above_either = 0
          @successful_above = 0
          @failed_above = 0
          @counts = Hash.new(0)
        end

        def observe(row, views, bucket_seconds)
          dest_over = over?(row, row.destination_domain, views[:destination], bucket_seconds, 'd')
          origin_over = over?(row, row.endpoint_origin, views[:origin], bucket_seconds, 'o')
          @above_destination += 1 if dest_over
          @above_origin += 1 if origin_over
          return unless row.destination_domain.present? && row.endpoint_origin.present?

          either = dest_over || origin_over
          return unless either

          @above_either += 1
          if row.success?
            @successful_above += 1
          else
            @failed_above += 1
          end
        end

        def to_h
          {
            'above_destination_cap' => @above_destination,
            'above_origin_cap' => @above_origin,
            'above_either_cap' => @above_either,
            'successful_above_either_cap' => @successful_above,
            'failed_above_either_cap' => @failed_above,
          }
        end

        private

        def over?(row, identity, view, bucket_seconds, prefix)
          return false if identity.blank? || view.nil?

          unix = row.event_time.to_i
          key = "#{prefix}:#{unix - (unix % bucket_seconds)}:#{identity}"
          next_count = @counts[key] + 1
          @counts[key] = next_count
          next_count > view.current_cap
        end
      end

      class LayerStats
        def initialize(params, ceiling)
          @params = params
          @ceiling = ceiling
          @before_caps = []
          @after_caps = []
          @failure_decreases = 0
          @rate_limit_decreases = 0
          @additive_increases = 0
          @stale_resets = 0
          @mutating = 0
          @at_min = 0
          @at_ceiling = 0
          @success_credits = []
        end

        def observe_before(view, event)
          @stale_resets += 1 if view.source == FollowImport::AdaptiveRemoteController::SOURCE_STALE_RESET
          return unless FollowImport::AdaptiveRemoteObservation.mutating?(event)

          @mutating += 1
          @before_caps << view.current_cap
          @at_min += 1 if view.current_cap == @params.min_cap
          @at_ceiling += 1 if view.current_cap == @ceiling
        end

        def observe_neutral
          nil
        end

        def observe_after(before, after, event)
          @after_caps << after.current_cap
          @failure_decreases += 1 if event == FollowImport::AdaptiveRemoteObservation::FAILURE && after.current_cap < before.current_cap
          @rate_limit_decreases += 1 if event == FollowImport::AdaptiveRemoteObservation::RATE_LIMIT && after.current_cap < before.current_cap
          @additive_increases += 1 if event == FollowImport::AdaptiveRemoteObservation::SUCCESS && after.current_cap > before.current_cap
          @success_credits << after.success_credit if event == FollowImport::AdaptiveRemoteObservation::SUCCESS
        end

        def to_h(store)
          {
            'keys_observed' => store.length,
            'cap_before' => Distribution.summary(@before_caps),
            'cap_after' => Distribution.summary(@after_caps),
            'minimum_reached' => @after_caps.min,
            'maximum_reached' => @after_caps.max,
            'decreases_due_failure' => @failure_decreases,
            'decreases_due_429' => @rate_limit_decreases,
            'additive_increases' => @additive_increases,
            'stale_resets' => @stale_resets,
            'mutating_event_count' => @mutating,
            'fraction_at_min_cap' => Distribution.ratio(@at_min, @mutating),
            'fraction_at_fixed_ceiling' => Distribution.ratio(@at_ceiling, @mutating),
            'success_credit' => Distribution.summary(@success_credits),
          }
        end
      end
    end
  end
end
