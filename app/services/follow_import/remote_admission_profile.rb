# frozen_string_literal: true

require 'digest'
require 'json'

# Parse/validate a fixed RemoteAdmission profile (PR F).
#
# No bundled production numeric defaults. Blank input is unconfigured.
# Malformed, incomplete, or illegal input is invalid and never raises
# to the scheduler. Unknown keys are rejected.
#
# Schema version 1 is structural only. Every number is operator-supplied
# and UNCALIBRATED. No value in this class is a production recommendation.
module FollowImport
  class RemoteAdmissionProfile
    SCHEMA_VERSION = 1
    SUPPORTED_VERSIONS = [SCHEMA_VERSION].freeze

    ENV_KEY = 'FOLLOW_IMPORT_REMOTE_ADMISSION_PROFILE'

    SOURCE_ENV          = 'env'
    SOURCE_INJECTED     = 'injected'
    SOURCE_UNCONFIGURED = 'unconfigured'
    SOURCE_INVALID      = 'invalid'

    TOP_KEYS     = %w(version destination origin runtime scan).freeze
    DEST_KEYS    = %w(per_tick_cap).freeze
    ORIGIN_KEYS  = %w(per_tick_cap).freeze
    RUNTIME_KEYS = %w(mapping_ttl_seconds max_retry_after_seconds recent_429_cooldown_seconds).freeze
    SCAN_KEYS    = %w(max_targets_per_batch max_windows_per_batch).freeze

    Destination = Struct.new(:per_tick_cap, keyword_init: true)
    Origin      = Struct.new(:per_tick_cap, keyword_init: true)
    Runtime     = Struct.new(:mapping_ttl_seconds, :max_retry_after_seconds, :recent_429_cooldown_seconds, keyword_init: true)
    Scan        = Struct.new(:max_targets_per_batch, :max_windows_per_batch, keyword_init: true)

    attr_reader :version, :destination, :origin, :runtime, :scan, :source, :error, :digest

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
      @destination = Destination.new
      @origin = Origin.new
      @runtime = Runtime.new
      @scan = Scan.new
      if payload.empty? && allow_blank
        @digest = nil
        return
      end

      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be #{SUPPORTED_VERSIONS.join(' or ')}"
      end

      reject_unknown!(payload.keys, TOP_KEYS, 'profile')
      parse_destination(payload['destination'])
      parse_origin(payload['origin'])
      parse_runtime(payload['runtime'])
      parse_scan(payload['scan'])
      @digest = Digest::SHA256.hexdigest(canonical_json)
    end

    def configured?
      source != SOURCE_UNCONFIGURED && source != SOURCE_INVALID
    end

    def invalid?
      source == SOURCE_INVALID
    end

    def destination_per_tick_cap
      destination.per_tick_cap
    end

    def origin_per_tick_cap
      origin.per_tick_cap
    end

    def mapping_ttl_seconds
      runtime.mapping_ttl_seconds
    end

    def max_retry_after_seconds
      runtime.max_retry_after_seconds
    end

    def recent_429_cooldown_seconds
      runtime.recent_429_cooldown_seconds
    end

    def max_targets_per_batch
      scan.max_targets_per_batch
    end

    def max_windows_per_batch
      scan.max_windows_per_batch
    end

    def scan_policy
      return unless configured?

      FollowImport::RemoteAdmission::ScanPolicy.new(
        max_targets_per_batch: max_targets_per_batch,
        max_windows_per_batch: max_windows_per_batch
      )
    end

    def identity
      {
        'remote_admission_profile_version' => version,
        'remote_admission_profile_digest' => digest,
        'destination_per_tick_cap' => destination_per_tick_cap,
        'origin_per_tick_cap' => origin_per_tick_cap,
        'max_scan_targets' => max_targets_per_batch,
        'max_scan_windows' => max_windows_per_batch,
      }
    end

    private

    def mark_invalid(message)
      @source = SOURCE_INVALID
      @error = message.to_s
      @version = nil
      @destination = Destination.new
      @origin = Origin.new
      @runtime = Runtime.new
      @scan = Scan.new
      @digest = nil
    end

    def parse_destination(raw)
      attrs = require_object(raw, 'destination', DEST_KEYS)
      @destination = Destination.new(per_tick_cap: require_positive_int(attrs['per_tick_cap'], 'destination.per_tick_cap'))
    end

    def parse_origin(raw)
      attrs = require_object(raw, 'origin', ORIGIN_KEYS)
      @origin = Origin.new(per_tick_cap: require_positive_int(attrs['per_tick_cap'], 'origin.per_tick_cap'))
    end

    def parse_runtime(raw)
      attrs = require_object(raw, 'runtime', RUNTIME_KEYS)
      @runtime = Runtime.new(
        mapping_ttl_seconds: require_positive_int(attrs['mapping_ttl_seconds'], 'runtime.mapping_ttl_seconds'),
        max_retry_after_seconds: require_positive_int(attrs['max_retry_after_seconds'], 'runtime.max_retry_after_seconds'),
        recent_429_cooldown_seconds: require_positive_int(attrs['recent_429_cooldown_seconds'], 'runtime.recent_429_cooldown_seconds')
      )
    end

    def parse_scan(raw)
      attrs = require_object(raw, 'scan', SCAN_KEYS)
      @scan = Scan.new(
        max_targets_per_batch: require_positive_int(attrs['max_targets_per_batch'], 'scan.max_targets_per_batch'),
        max_windows_per_batch: require_positive_int(attrs['max_windows_per_batch'], 'scan.max_windows_per_batch')
      )
    end

    def require_object(raw, label, allowed)
      raise ArgumentError, "#{label} is required" if raw.nil?
      raise ArgumentError, "#{label} must be an object" unless raw.is_a?(Hash)

      attrs = stringify(raw)
      reject_unknown!(attrs.keys, allowed, label)
      attrs
    end

    def require_positive_int(value, label)
      raise ArgumentError, "#{label} is required" if value.nil?
      raise ArgumentError, "#{label} must be a number" unless value.is_a?(Numeric)
      raise ArgumentError, "#{label} must be an integer" if value != value.to_i
      raise ArgumentError, "#{label} must be > 0" unless value.to_i.positive?

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
        'destination' => { 'per_tick_cap' => destination_per_tick_cap },
        'origin' => { 'per_tick_cap' => origin_per_tick_cap },
        'runtime' => {
          'mapping_ttl_seconds' => mapping_ttl_seconds,
          'max_retry_after_seconds' => max_retry_after_seconds,
          'recent_429_cooldown_seconds' => recent_429_cooldown_seconds,
        },
        'scan' => {
          'max_targets_per_batch' => max_targets_per_batch,
          'max_windows_per_batch' => max_windows_per_batch,
        }
      )
    end
  end
end
