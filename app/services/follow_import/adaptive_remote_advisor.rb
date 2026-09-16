# frozen_string_literal: true

# Shadow sidecar around fixed RemoteAdmission (PR G).
#
# Actual claim / skip is ALWAYS the wrapped PR F (or NullAdmission)
# decision. Adaptive evaluation cannot overwrite it:
#
#   base deny  -> deny
#   base admit -> still admit, even when adaptive would have blocked
#
# Adaptive caps are always <= the corresponding PR F fixed caps.
# Among actual fixed admits, a per-tick hypothetical destination /
# origin counter asks "would adaptive enforcement have blocked this
# current claim?". That is not a full alternate scheduler simulation
# and must not be named as if a second plan was computed.
#
# Local destinations are excluded. Missing destination_domain is not
# persisted; the shadow recommendation uses the conservative initial
# destination cap. Mapping-absent candidates evaluate destination
# only. Mapping-present candidates evaluate destination + shared origin.
#
# Shadow routing uses the planner candidate, not the base decision
# payload. NullAdmission (PR F enforcement off) admits without
# destination / origin metadata; the sidecar still reads
# candidate[:destination_domain] and an observation-only
# RemoteRuntimeState snapshot for destination → origin mapping.
# That snapshot must not apply destination/origin caps,
# UnavailableDomain, or Retry-After / recent-429 suppression.
#
# Sidecar exceptions never abort the actual PR F / PR C plan.
module FollowImport
  class AdaptiveRemoteAdvisor
    def initialize(admission:, adaptive_profile:, fixed_profile:, state:, runtime: nil, now: Time.now.utc)
      @admission = admission
      @adaptive_profile = adaptive_profile
      @fixed_profile = fixed_profile
      @state = state
      @runtime = runtime
      @now = now
      @shadow_by_destination = Hash.new(0)
      @shadow_by_origin = Hash.new(0)
      @evaluated_current_claim_count = 0
      @would_block_current_claim_count = 0
      @destination_would_block_count = 0
      @origin_would_block_count = 0
      @runtime_unavailable_count = 0
      @destination_sources = Hash.new(0)
      @origin_sources = Hash.new(0)
      @destination_caps = []
      @origin_caps = []
    end

    def evaluated?
      true
    end

    def decide(candidate)
      decision = @admission.decide(candidate)
      evaluate_shadow(candidate, decision) if decision.admit?
      decision
    end

    def record_admit(decision)
      @admission.record_admit(decision)
    end

    def record_skip(decision)
      @admission.record_skip(decision)
    end

    def stats
      @admission.stats.merge(
        'adaptive_remote_shadow_enabled' => true,
        'adaptive_remote_configured' => true,
        'adaptive_profile_version' => @adaptive_profile.version,
        'adaptive_shadow_evaluated_current_claim_count' => @evaluated_current_claim_count,
        'adaptive_shadow_would_block_current_claim_count' => @would_block_current_claim_count,
        'adaptive_shadow_destination_would_block_count' => @destination_would_block_count,
        'adaptive_shadow_origin_would_block_count' => @origin_would_block_count,
        'adaptive_runtime_unavailable_count' => @runtime_unavailable_count,
        'adaptive_destination_cap_min' => @destination_caps.min,
        'adaptive_destination_cap_max' => @destination_caps.max,
        'adaptive_origin_cap_min' => @origin_caps.min,
        'adaptive_origin_cap_max' => @origin_caps.max,
        'adaptive_destination_state_sources' => @destination_sources.dup,
        'adaptive_origin_state_sources' => @origin_sources.dup
      )
    end

    def planned_by_destination
      @admission.respond_to?(:planned_by_destination) ? @admission.planned_by_destination : {}
    end

    def planned_by_origin
      @admission.respond_to?(:planned_by_origin) ? @admission.planned_by_origin : {}
    end

    private

    def evaluate_shadow(candidate, decision)
      dest_key = candidate_destination(candidate)
      return if local_destination?(dest_key)

      dest_view = destination_view(dest_key)
      origin_key = mapping_origin(dest_key)
      origin_key ||= decision.endpoint_origin.presence if decision.respond_to?(:endpoint_origin)
      origin_view = origin_key.present? ? origin_view_for(origin_key) : nil

      @evaluated_current_claim_count += 1

      dest_block = dest_view && @shadow_by_destination[shadow_destination_key(dest_key)] >= dest_view.current_cap
      origin_block = origin_view && @shadow_by_origin[origin_key] >= origin_view.current_cap

      if dest_block || origin_block
        @would_block_current_claim_count += 1
        @destination_would_block_count += 1 if dest_block
        @origin_would_block_count += 1 if origin_block
        return
      end

      @shadow_by_destination[shadow_destination_key(dest_key)] += 1 if dest_view
      @shadow_by_origin[origin_key] += 1 if origin_view
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('adaptive_remote_shadow', e)
    end

    def destination_view(destination_domain)
      view = @state.view_for_destination(destination_domain)
      record_destination_view(view)
      view
    end

    def origin_view_for(endpoint_origin)
      view = @state.view_for_origin(endpoint_origin)
      record_origin_view(view)
      view
    end

    def record_destination_view(view)
      return if view.nil?

      @destination_caps << view.current_cap
      @destination_sources[view.source] += 1
      @runtime_unavailable_count += 1 if view.source == FollowImport::AdaptiveRemoteController::SOURCE_RUNTIME_UNAVAILABLE
    end

    def record_origin_view(view)
      return if view.nil?

      @origin_caps << view.current_cap
      @origin_sources[view.source] += 1
      @runtime_unavailable_count += 1 if view.source == FollowImport::AdaptiveRemoteController::SOURCE_RUNTIME_UNAVAILABLE
    end

    def candidate_destination(candidate)
      return if candidate.nil?
      return unless candidate.respond_to?(:[])

      candidate[:destination_domain].to_s.presence || candidate['destination_domain'].to_s.presence
    end

    def mapping_origin(destination_domain)
      return if destination_domain.blank?
      return unless @runtime.respond_to?(:mapping_for)

      @runtime.mapping_for(destination_domain)&.endpoint_origin.presence
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('adaptive_remote_mapping', e)
      nil
    end

    def shadow_destination_key(destination_domain)
      destination_domain.presence || FollowImport::RemoteAdmission::UNKNOWN_DESTINATION
    end

    def local_destination?(domain)
      return false if domain.blank?

      TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
    end
  end
end
