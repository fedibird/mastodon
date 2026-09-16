# frozen_string_literal: true

require 'set'

# Fixed (non-adaptive) remote admission for GLOBAL Follow Import ticks.
#
# Decision inputs are only:
#   - the operator-configured RemoteAdmissionProfile
#   - current per-tick planned counters
#   - exact UnavailableDomain hosts (one snapshot)
#   - memoized RemoteRuntimeState (mapping + suppression)
#
# Accept / Reject / Follow Gate / moderation / NodeInfo / software-type
# / user-count / AIMD / latency-derived rates are not consulted.
#
# Local destinations consume GLOBAL / local-load budget but not remote
# destination or origin caps, and are not checked against UnavailableDomain.
# Missing destination_domain uses a synthetic unknown bucket so it is never
# treated as unlimited. That synthetic key is never persisted.
module FollowImport
  class RemoteAdmission
    UNKNOWN_DESTINATION = '__unknown_destination__'

    ScanPolicy = Struct.new(:max_targets_per_batch, :max_windows_per_batch, keyword_init: true)

    attr_reader :profile, :planned_by_destination, :planned_by_origin

    def initialize(profile:, runtime:, unavailable_hosts: nil, unavailable_snapshot_available: true, now: Time.now.utc)
      @profile = profile
      @runtime = runtime
      @unavailable_hosts = unavailable_hosts || Set.new
      @unavailable_snapshot_available = unavailable_snapshot_available
      @now = now
      @planned_by_destination = Hash.new(0)
      @planned_by_origin = Hash.new(0)
      @skip_counts = Hash.new(0)
      @mapped_origin_candidate_count = 0
    end

    def evaluated?
      true
    end

    def decide(candidate)
      dest = candidate[:destination_domain].to_s.presence
      extra = []

      if local_destination?(dest)
        return FollowImport::RemoteAdmissionDecision.admit(
          reason: 'local_destination',
          destination_domain: dest,
          runtime_state_source: FollowImport::RemoteAdmissionDecision::SOURCE_LOCAL,
          routing_key: dest
        )
      end

      missing = dest.nil?
      routing_key = missing ? UNKNOWN_DESTINATION : dest
      extra << 'missing_destination' if missing

      origin = lookup_origin(routing_key) unless missing
      @mapped_origin_candidate_count += 1 if origin.present?
      # Recompute after mapping_for so a first-lookup Redis failure is
      # recorded as runtime_state_unavailable, not unknown.
      runtime_source = runtime_state_source
      extra << 'runtime_state_unavailable' if runtime_source == FollowImport::RemoteAdmissionDecision::SOURCE_UNAVAILABLE
      runtime_source = if runtime_source == FollowImport::RemoteAdmissionDecision::SOURCE_UNAVAILABLE
                         runtime_source
                       elsif origin.present?
                         FollowImport::RemoteAdmissionDecision::SOURCE_REDIS
                       else
                         FollowImport::RemoteAdmissionDecision::SOURCE_UNKNOWN
                       end

      if @unavailable_snapshot_available
        if dest.present? && unavailable_host?(dest)
          return deny('unavailable_destination', dest, origin, runtime_source, routing_key, extra)
        end
        if origin.present? && unavailable_host?(host_from_origin(origin))
          return deny('unavailable_origin', dest, origin, runtime_source, routing_key, extra)
        end
      end

      if origin.present? && runtime_available?
        suppression = @runtime.suppression_for(origin)
        if suppression && suppression.honor_until && suppression.honor_until > @now
          reason = suppression.reason == 'recent_429' ? 'recent_429' : 'retry_after'
          return deny(reason, dest, origin, runtime_source, routing_key, extra)
        end
      end

      if @planned_by_destination[routing_key] >= @profile.destination_per_tick_cap
        return deny('destination_cap', dest || UNKNOWN_DESTINATION, origin, runtime_source, routing_key, extra)
      end

      if origin.present? && @planned_by_origin[origin] >= @profile.origin_per_tick_cap
        return deny('origin_cap', dest, origin, runtime_source, routing_key, extra)
      end

      FollowImport::RemoteAdmissionDecision.admit(
        reason: 'admitted',
        destination_domain: dest,
        endpoint_origin: origin,
        runtime_state_source: runtime_source,
        routing_key: routing_key,
        reasons: extra
      )
    end

    def record_admit(decision)
      return if decision.reason == 'local_destination'

      @planned_by_destination[decision.routing_key] += 1
      @planned_by_origin[decision.endpoint_origin] += 1 if decision.endpoint_origin.present?
    end

    def record_skip(decision)
      key = case decision.reason
            when 'destination_cap' then 'skipped_destination_cap_count'
            when 'origin_cap' then 'skipped_origin_cap_count'
            when 'unavailable_destination', 'unavailable_origin' then 'skipped_unavailable_count'
            when 'retry_after' then 'skipped_retry_after_count'
            when 'recent_429' then 'skipped_recent_429_count'
            end
      @skip_counts[key] += 1 if key
    end

    def stats
      {
        'skipped_destination_cap_count' => @skip_counts['skipped_destination_cap_count'].to_i,
        'skipped_origin_cap_count' => @skip_counts['skipped_origin_cap_count'].to_i,
        'skipped_unavailable_count' => @skip_counts['skipped_unavailable_count'].to_i,
        'skipped_retry_after_count' => @skip_counts['skipped_retry_after_count'].to_i,
        'skipped_recent_429_count' => @skip_counts['skipped_recent_429_count'].to_i,
        'mapped_origin_candidate_count' => @mapped_origin_candidate_count,
      }
    end

    # Exact known-host snapshot. Failure to read is not proof every host
    # is healthy; the caller passes unavailable_snapshot_available=false
    # and admission continues with the destination cap only.
    def self.unavailable_hosts
      map = Rails.cache.fetch('unavailable_domains') { UnavailableDomain.pluck(:domain).index_with(true) }
      [map.keys.to_set, true]
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('remote_admission_unavailable_hosts', e)
      [Set.new, false]
    end

    class NullAdmission
      def evaluated?
        false
      end

      def decide(_candidate)
        FollowImport::RemoteAdmissionDecision.admit(reason: 'admitted')
      end

      def record_admit(_decision); end

      def record_skip(_decision); end

      def stats
        {}
      end
    end

    private

    def lookup_origin(destination_domain)
      return unless runtime_available?

      @runtime.mapping_for(destination_domain)&.endpoint_origin.presence
    end

    def runtime_available?
      @runtime.respond_to?(:available?) ? @runtime.available? : true
    end

    def runtime_state_source
      return FollowImport::RemoteAdmissionDecision::SOURCE_NONE if @runtime.nil?
      return FollowImport::RemoteAdmissionDecision::SOURCE_UNAVAILABLE unless runtime_available?

      FollowImport::RemoteAdmissionDecision::SOURCE_REDIS
    end

    def local_destination?(domain)
      return false if domain.blank?

      TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
    end

    def unavailable_host?(host)
      return false if host.blank?

      @unavailable_hosts.include?(host)
    end

    def host_from_origin(origin)
      Addressable::URI.parse(origin).normalized_host.presence
    rescue StandardError
      nil
    end

    def deny(reason, dest, origin, runtime_source, routing_key, extra)
      FollowImport::RemoteAdmissionDecision.deny(
        reason: reason,
        destination_domain: dest,
        endpoint_origin: origin,
        runtime_state_source: runtime_source,
        routing_key: routing_key,
        reasons: extra
      )
    end
  end
end
