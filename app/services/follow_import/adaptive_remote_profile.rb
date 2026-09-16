# frozen_string_literal: true

require 'digest'
require 'json'

# Parse/validate a shadow adaptive remote-pacing profile (PR G).
#
# This is NOT a replacement for FollowImport::RemoteAdmissionProfile.
# Adaptive caps are always an inner shrink of the corresponding PR F
# fixed destination / origin per-tick caps (hard ceiling). Compatibility
# with that baseline is checked separately by
# FollowImport::AdaptiveRemoteCompatibility.
#
# No bundled production numeric defaults. Blank input is unconfigured.
# Malformed, incomplete, or illegal input is invalid and never raises
# to the scheduler or delivery path. Unknown keys are rejected.
#
# Schema version 1 is structural only. Every number is operator-supplied
# and UNCALIBRATED. No value in this class is a production recommendation.
module FollowImport
  class AdaptiveRemoteProfile
    SCHEMA_VERSION = 1
    SUPPORTED_VERSIONS = [SCHEMA_VERSION].freeze

    ENV_KEY = 'FOLLOW_IMPORT_REMOTE_ADAPTIVE_PROFILE'

    SOURCE_ENV          = 'env'
    SOURCE_INJECTED     = 'injected'
    SOURCE_UNCONFIGURED = 'unconfigured'
    SOURCE_INVALID      = 'invalid'

    TOP_KEYS        = %w(version destination origin runtime).freeze
    CONTROLLER_KEYS = %w(
      initial_cap
      min_cap
      additive_step
      successes_per_increase
      failure_multiplier_percent
      rate_limit_multiplier_percent
    ).freeze
    RUNTIME_KEYS = %w(stale_after_seconds state_ttl_seconds).freeze

    Controller = Struct.new(
      :initial_cap,
      :min_cap,
      :additive_step,
      :successes_per_increase,
      :failure_multiplier_percent,
      :rate_limit_multiplier_percent,
      keyword_init: true
    )
    Runtime = Struct.new(:stale_after_seconds, :state_ttl_seconds, keyword_init: true)

    attr_reader :version, :destination, :origin, :runtime, :source, :error, :digest

    def self.from_env
      if ENV.key?(ENV_KEY)
        parse(ENV[ENV_KEY], source: SOURCE_ENV)
      else
        unconfigured
      end
    end

    def self.parse(raw, source: SOURCE_INJECTED)
      return unconfigured if raw.nil? || (raw.is_a?(String) && raw.blank?)
      return parse(raw.to_json, source: source) if raw.is_a?(Hash)
      return invalid('profile must be a JSON object') unless raw.is_a?(String)

      data = JSON.parse(raw)
      return invalid('profile must be a JSON object') unless data.is_a?(Hash)

      build(data, source: source)
    rescue JSON::ParserError => e
      invalid(e.message)
    rescue StandardError => e
      invalid(e.class.name)
    end

    def self.build(data, source: SOURCE_INJECTED)
      new(data, source)
    rescue ArgumentError => e
      invalid(e.message)
    end

    def self.unconfigured
      new({}, SOURCE_UNCONFIGURED, allow_blank: true)
    end

    def self.invalid(message)
      instance = allocate
      instance.send(:mark_invalid, message)
      instance
    end

    def initialize(data, source, allow_blank: false)
      @source = source
      payload = stringify(data)
      @version = payload['version']
      @destination = Controller.new
      @origin = Controller.new
      @runtime = Runtime.new
      if payload.empty? && allow_blank
        @digest = nil
        return
      end

      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be #{SUPPORTED_VERSIONS.join(' or ')}"
      end

      reject_unknown!(payload.keys, TOP_KEYS, 'profile')
      @destination = parse_controller(payload['destination'], 'destination')
      @origin = parse_controller(payload['origin'], 'origin')
      parse_runtime(payload['runtime'])
      @digest = Digest::SHA256.hexdigest(canonical_json)
    end

    def configured?
      source != SOURCE_UNCONFIGURED && source != SOURCE_INVALID
    end

    def invalid?
      source == SOURCE_INVALID
    end

    def stale_after_seconds
      runtime.stale_after_seconds
    end

    def state_ttl_seconds
      runtime.state_ttl_seconds
    end

    def identity
      {
        'adaptive_profile_version' => version,
        'adaptive_profile_digest' => digest,
      }
    end

    private

    def mark_invalid(message)
      @source = SOURCE_INVALID
      @error = message.to_s
      @version = nil
      @destination = Controller.new
      @origin = Controller.new
      @runtime = Runtime.new
      @digest = nil
    end

    def parse_controller(raw, label)
      attrs = require_object(raw, label, CONTROLLER_KEYS)
      initial_cap = require_positive_int(attrs['initial_cap'], "#{label}.initial_cap")
      min_cap = require_positive_int(attrs['min_cap'], "#{label}.min_cap")
      raise ArgumentError, "#{label}.min_cap must be <= #{label}.initial_cap" if min_cap > initial_cap

      additive_step = require_positive_int(attrs['additive_step'], "#{label}.additive_step")
      successes_per_increase = require_positive_int(attrs['successes_per_increase'], "#{label}.successes_per_increase")
      failure_percent = require_open_percent(attrs['failure_multiplier_percent'], "#{label}.failure_multiplier_percent")
      rate_limit_percent = require_open_percent(attrs['rate_limit_multiplier_percent'], "#{label}.rate_limit_multiplier_percent")
      if rate_limit_percent > failure_percent
        raise ArgumentError, "#{label}.rate_limit_multiplier_percent must be <= #{label}.failure_multiplier_percent"
      end

      Controller.new(
        initial_cap: initial_cap,
        min_cap: min_cap,
        additive_step: additive_step,
        successes_per_increase: successes_per_increase,
        failure_multiplier_percent: failure_percent,
        rate_limit_multiplier_percent: rate_limit_percent
      )
    end

    def parse_runtime(raw)
      attrs = require_object(raw, 'runtime', RUNTIME_KEYS)
      stale_after = require_positive_int(attrs['stale_after_seconds'], 'runtime.stale_after_seconds')
      state_ttl = require_positive_int(attrs['state_ttl_seconds'], 'runtime.state_ttl_seconds')
      raise ArgumentError, 'runtime.state_ttl_seconds must be >= runtime.stale_after_seconds' if state_ttl < stale_after

      @runtime = Runtime.new(stale_after_seconds: stale_after, state_ttl_seconds: state_ttl)
    end

    def require_object(raw, label, allowed)
      raise ArgumentError, "#{label} is required" if raw.nil?
      raise ArgumentError, "#{label} must be an object" unless raw.is_a?(Hash)

      attrs = stringify(raw)
      reject_unknown!(attrs.keys, allowed, label)
      attrs
    end

    def require_positive_int(value, label)
      integer = require_integer(value, label)
      raise ArgumentError, "#{label} must be > 0" unless integer.positive?

      integer
    end

    def require_open_percent(value, label)
      integer = require_integer(value, label)
      raise ArgumentError, "#{label} must be > 0 and < 100" unless integer.positive? && integer < 100

      integer
    end

    def require_integer(value, label)
      raise ArgumentError, "#{label} is required" if value.nil?
      raise ArgumentError, "#{label} must be a number" unless value.is_a?(Numeric)
      raise ArgumentError, "#{label} must be an integer" if value != value.to_i

      value.to_i
    end

    def reject_unknown!(keys, allowed, label)
      unknown = keys.map(&:to_s) - allowed
      raise ArgumentError, "unknown #{label} keys: #{unknown.join(', ')}" if unknown.any?
    end

    def stringify(value)
      value.to_h.transform_keys(&:to_s)
    end

    def canonical_json
      JSON.generate(
        'version' => @version,
        'destination' => controller_hash(@destination),
        'origin' => controller_hash(@origin),
        'runtime' => {
          'stale_after_seconds' => stale_after_seconds,
          'state_ttl_seconds' => state_ttl_seconds,
        }
      )
    end

    def controller_hash(controller)
      {
        'initial_cap' => controller.initial_cap,
        'min_cap' => controller.min_cap,
        'additive_step' => controller.additive_step,
        'successes_per_increase' => controller.successes_per_increase,
        'failure_multiplier_percent' => controller.failure_multiplier_percent,
        'rate_limit_multiplier_percent' => controller.rate_limit_multiplier_percent,
      }
    end
  end
end
