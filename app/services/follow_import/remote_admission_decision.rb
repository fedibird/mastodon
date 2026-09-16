# frozen_string_literal: true

# Structured remote-admission result for one Follow Import candidate.
# Machine-readable +reason+ is the primary state. +reasons+ may list
# additional facts. Human prose is never the primary state.
module FollowImport
  class RemoteAdmissionDecision
    REASONS = %w(
      local_destination
      admitted
      destination_cap
      origin_cap
      unavailable_destination
      unavailable_origin
      retry_after
      recent_429
      missing_destination
      runtime_state_unavailable
    ).freeze

    SOURCE_REDIS       = 'redis'
    SOURCE_UNKNOWN     = 'unknown'
    SOURCE_UNAVAILABLE = 'unavailable'
    SOURCE_LOCAL       = 'local'
    SOURCE_NONE        = 'none'

    attr_reader :reason, :reasons, :destination_domain, :endpoint_origin, :runtime_state_source, :routing_key

    def self.admit(**attrs)
      new(admit: true, **attrs)
    end

    def self.deny(**attrs)
      new(admit: false, **attrs)
    end

    def initialize(admit:, reason:, destination_domain: nil, endpoint_origin: nil, runtime_state_source: SOURCE_NONE, routing_key: nil, reasons: nil)
      @admit = admit
      @reason = reason.to_s
      extra = Array(reasons).map(&:to_s)
      @reasons = ([@reason] + extra).uniq
      @destination_domain = destination_domain
      @endpoint_origin = endpoint_origin
      @runtime_state_source = runtime_state_source
      @routing_key = routing_key || destination_domain
    end

    def admit?
      @admit
    end
  end
end
