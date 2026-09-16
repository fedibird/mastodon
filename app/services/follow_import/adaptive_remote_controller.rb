# frozen_string_literal: true

# Pure AIMD / slow-recovery control law for Follow Import remote pacing.
#
# This controller never replaces PR F fixed RemoteAdmission. It only
# recommends a cap that is always:
#
#   adaptive_cap <= corresponding fixed destination/origin per-tick cap
#
# Successful 2xx observations accumulate credit and rise additively
# toward that fixed ceiling. They never go above it. 429 uses the
# stronger rate-limit multiplier. 5xx / timeout / connection / SSL
# use the generic failure multiplier. Ordinary 4xx, 3xx, unknown
# exceptions, Stoplight-before-request, latency, Accept/Reject, and
# follow business states are not inputs.
#
# Stale or digest-mismatched state returns to the conservative
# initial_cap. Lost Redis state is the same as unknown: initial_cap.
# There are no production numeric defaults here; every coefficient
# comes from an operator-supplied AdaptiveRemoteProfile.
module FollowImport
  class AdaptiveRemoteController
    SCHEMA_VERSION = 1

    SOURCE_INITIAL              = 'initial'
    SOURCE_LEARNED              = 'learned'
    SOURCE_STALE_RESET          = 'stale_reset'
    SOURCE_DIGEST_RESET         = 'digest_reset'
    SOURCE_CORRUPT_RESET        = 'corrupt_reset'
    SOURCE_RUNTIME_UNAVAILABLE  = 'runtime_unavailable'

    View = Struct.new(
      :schema_version,
      :current_cap,
      :success_credit,
      :observed_at,
      :adaptive_profile_digest,
      :fixed_profile_digest,
      :source,
      keyword_init: true
    )

    def self.initial_view(params, now:, adaptive_digest:, fixed_digest:, ceiling:, source: SOURCE_INITIAL)
      View.new(
        schema_version: SCHEMA_VERSION,
        current_cap: clamp(params.initial_cap, params.min_cap, ceiling),
        success_credit: 0,
        observed_at: now,
        adaptive_profile_digest: adaptive_digest,
        fixed_profile_digest: fixed_digest,
        source: source
      )
    end

    def self.view_from_payload(payload, params:, now:, stale_after:, adaptive_digest:, fixed_digest:, ceiling:)
      unless payload.is_a?(Hash) && payload['schema_version'].to_i == SCHEMA_VERSION
        return initial_view(params, now: now, adaptive_digest: adaptive_digest, fixed_digest: fixed_digest, ceiling: ceiling, source: SOURCE_CORRUPT_RESET)
      end

      unless payload['adaptive_profile_digest'].to_s == adaptive_digest.to_s &&
             payload['fixed_profile_digest'].to_s == fixed_digest.to_s
        return initial_view(params, now: now, adaptive_digest: adaptive_digest, fixed_digest: fixed_digest, ceiling: ceiling, source: SOURCE_DIGEST_RESET)
      end

      observed_at = parse_time(payload['observed_at']) || parse_unix(payload['observed_at_unix'])
      if stale?(observed_at, now, stale_after)
        return initial_view(params, now: now, adaptive_digest: adaptive_digest, fixed_digest: fixed_digest, ceiling: ceiling, source: SOURCE_STALE_RESET)
      end

      View.new(
        schema_version: SCHEMA_VERSION,
        current_cap: clamp(payload['current_cap'].to_i, params.min_cap, ceiling),
        success_credit: [payload['success_credit'].to_i, 0].max,
        observed_at: observed_at,
        adaptive_profile_digest: adaptive_digest,
        fixed_profile_digest: fixed_digest,
        source: SOURCE_LEARNED
      )
    end

    def self.apply(view, event, params, ceiling:, now:, adaptive_digest:, fixed_digest:)
      working = view || initial_view(
        params,
        now: now,
        adaptive_digest: adaptive_digest,
        fixed_digest: fixed_digest,
        ceiling: ceiling
      )
      cap = clamp(working.current_cap, params.min_cap, ceiling)
      credit = [working.success_credit.to_i, 0].max

      case event.to_s
      when FollowImport::AdaptiveRemoteObservation::SUCCESS
        credit += 1
        while credit >= params.successes_per_increase
          cap += params.additive_step
          credit -= params.successes_per_increase
        end
      when FollowImport::AdaptiveRemoteObservation::RATE_LIMIT
        cap = (cap * params.rate_limit_multiplier_percent) / 100
        credit = 0
      when FollowImport::AdaptiveRemoteObservation::FAILURE
        cap = (cap * params.failure_multiplier_percent) / 100
        credit = 0
      else
        return working
      end

      View.new(
        schema_version: SCHEMA_VERSION,
        current_cap: clamp(cap, params.min_cap, ceiling),
        success_credit: credit,
        observed_at: now,
        adaptive_profile_digest: adaptive_digest,
        fixed_profile_digest: fixed_digest,
        source: working.source
      )
    end

    def self.clamp(cap, min_cap, ceiling)
      [[cap.to_i, min_cap.to_i].max, ceiling.to_i].min
    end

    def self.stale?(observed_at, now, stale_after)
      return true if observed_at.nil?

      observed_at + stale_after.to_i < now
    end

    def self.parse_time(value)
      return if value.blank?
      return value if value.is_a?(Time)

      Time.iso8601(value.to_s)
    rescue StandardError
      nil
    end

    def self.parse_unix(value)
      return if value.blank?

      Time.at(value.to_i).utc
    rescue StandardError
      nil
    end
  end
end
