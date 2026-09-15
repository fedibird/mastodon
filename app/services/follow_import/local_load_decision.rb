# frozen_string_literal: true

# Immutable local-load recommendation. Observation only in PR D.
# recommended_budget nil means the controller did not compute a usable
# number (disabled / unconfigured / invalid / unknown). 0 means it
# computed zero and the SHADOW plan would skip.
module FollowImport
  class LocalLoadDecision
    STATES = %w(disabled unconfigured invalid unknown normal busy heavy overloaded).freeze

    attr_reader :state, :base_budget, :recommended_budget, :budget_percent,
                :would_skip, :reasons, :measurement_complete, :profile_version,
                :profile_source, :profile_digest

    def initialize(attrs)
      attrs = attrs.to_h.symbolize_keys
      @state = attrs.fetch(:state).to_s
      @base_budget = attrs[:base_budget]
      @recommended_budget = attrs[:recommended_budget]
      @budget_percent = attrs[:budget_percent]
      @would_skip = attrs[:would_skip]
      @reasons = Array(attrs[:reasons]).map(&:to_s)
      @measurement_complete = attrs[:measurement_complete]
      @profile_version = attrs[:profile_version]
      @profile_source = attrs[:profile_source]
      @profile_digest = attrs[:profile_digest]
    end

    def apply_to_shadow_plan?
      measurement_complete == true && !recommended_budget.nil?
    end

    def would_skip?
      would_skip
    end

    def measurement_complete?
      measurement_complete
    end

    def self.disabled(base_budget)
      new(state: 'disabled', base_budget: base_budget, reasons: [])
    end

    def self.unconfigured(base_budget, profile = nil)
      new(
        state: 'unconfigured',
        base_budget: base_budget,
        reasons: %w(profile_unconfigured),
        profile_version: profile&.version,
        profile_source: profile&.source || FollowImport::LocalLoadProfile::SOURCE_UNCONFIGURED,
        profile_digest: profile&.digest
      )
    end

    def self.invalid(base_budget, profile = nil)
      new(
        state: 'invalid',
        base_budget: base_budget,
        reasons: %w(profile_invalid),
        profile_version: profile&.version,
        profile_source: profile&.source || FollowImport::LocalLoadProfile::SOURCE_INVALID,
        profile_digest: profile&.digest
      )
    end

    def self.unknown(base_budget, profile, missing_reasons)
      new(
        state: 'unknown',
        base_budget: base_budget,
        measurement_complete: false,
        reasons: Array(missing_reasons).presence || %w(measurement_missing),
        profile_version: profile.version,
        profile_source: profile.source,
        profile_digest: profile.digest
      )
    end
  end
end
