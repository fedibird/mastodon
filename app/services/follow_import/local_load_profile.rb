# frozen_string_literal: true

require 'digest'
require 'json'

# Parse/validate a local-load profile. No bundled production numeric
# defaults. Blank input is unconfigured. Malformed or illegal input is
# invalid and never raises to the worker or scheduler.
#
# Schema version 1 (PR D / shadow observation):
#   version (required, must be 1)
#   levels.busy|heavy|overloaded.budget_percent 0..100
#   levels.*.default|push|pull.size|latency  (optional, non-negative)
#   levels.*.retry_size                      (optional, non-negative)
#   capacity.max_tick_claims / per_push_thread / per_pull_thread
#
# Schema version 2 (enforcement-capable):
#   everything in v1, plus required
#   fallback.budget_percent 0..100
#
# Live enforcement requires v2. v1 remains valid for shadow observation.
# Stronger levels must not recommend a larger budget percent than weaker
# ones. Configured thresholds must be non-decreasing busy → heavy →
# overloaded for the same signal.
#
# Canonical ENV is FOLLOW_IMPORT_LOCAL_LOAD_PROFILE. The PR D name
# FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE is a deprecated alias used
# only when the canonical variable is absent.
module FollowImport
  class LocalLoadProfile
    SCHEMA_VERSION_V1 = 1
    SCHEMA_VERSION_V2 = 2
    SCHEMA_VERSION = SCHEMA_VERSION_V2
    SUPPORTED_VERSIONS = [SCHEMA_VERSION_V1, SCHEMA_VERSION_V2].freeze

    ENV_KEY        = 'FOLLOW_IMPORT_LOCAL_LOAD_PROFILE'
    LEGACY_ENV_KEY = 'FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE'

    SOURCE_ENV           = 'env'
    SOURCE_ENV_LEGACY    = 'env_legacy'
    SOURCE_INJECTED      = 'injected'
    SOURCE_UNCONFIGURED  = 'unconfigured'
    SOURCE_INVALID       = 'invalid'

    LEVEL_NAMES = %w(busy heavy overloaded).freeze
    QUEUE_NAMES = %w(default push pull).freeze
    QUEUE_FIELDS = %w(size latency).freeze
    TOP_KEYS_V1 = %w(version levels capacity).freeze
    TOP_KEYS_V2 = %w(version levels capacity fallback).freeze
    LEVEL_KEYS = %w(budget_percent default push pull retry_size).freeze
    CAPACITY_KEYS = %w(max_tick_claims per_push_thread per_pull_thread).freeze
    FALLBACK_KEYS = %w(budget_percent).freeze

    Level = Struct.new(:name, :budget_percent, :queues, :retry_size, keyword_init: true)
    Capacity = Struct.new(:max_tick_claims, :per_push_thread, :per_pull_thread, keyword_init: true)
    Fallback = Struct.new(:budget_percent, keyword_init: true)

    attr_reader :version, :levels, :capacity, :fallback, :source, :error, :digest

    def self.from_env
      if ENV.key?(ENV_KEY)
        parse(ENV[ENV_KEY], source: SOURCE_ENV)
      elsif ENV.key?(LEGACY_ENV_KEY)
        parse(ENV[LEGACY_ENV_KEY], source: SOURCE_ENV_LEGACY)
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
      @levels = {}
      @capacity = Capacity.new
      @fallback = nil
      if payload.empty? && allow_blank
        @digest = nil
        return
      end

      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be #{SUPPORTED_VERSIONS.join(' or ')}"
      end

      reject_unknown!(payload.keys, top_keys_for(@version), 'profile')
      parse_levels(payload['levels'])
      parse_capacity(payload['capacity'])
      parse_fallback(payload['fallback']) if @version == SCHEMA_VERSION_V2
      validate_monotonicity!
      @digest = Digest::SHA256.hexdigest(canonical_json)
    end

    def configured?
      source != SOURCE_UNCONFIGURED && source != SOURCE_INVALID
    end

    def invalid?
      source == SOURCE_INVALID
    end

    # Live enforcement requires an explicit v2 fallback. v1 is observation-only.
    def enforcement_capable?
      configured? && version == SCHEMA_VERSION_V2 && !fallback.nil?
    end

    def level(name)
      @levels[name.to_s]
    end

    def fallback_budget(base)
      return if fallback.nil?

      (base.to_i * fallback.budget_percent) / 100
    end

    private

    def mark_invalid(message)
      @source = SOURCE_INVALID
      @error = message.to_s
      @version = nil
      @levels = {}
      @capacity = Capacity.new
      @fallback = nil
      @digest = nil
    end

    def top_keys_for(version)
      version == SCHEMA_VERSION_V2 ? TOP_KEYS_V2 : TOP_KEYS_V1
    end

    def parse_levels(raw)
      return if raw.nil?
      raise ArgumentError, 'levels must be an object' unless raw.is_a?(Hash)

      raw.each do |name, body|
        raise ArgumentError, "unknown level #{name}" unless LEVEL_NAMES.include?(name.to_s)
        raise ArgumentError, "level #{name} must be an object" unless body.is_a?(Hash)

        attrs = stringify(body)
        reject_unknown!(attrs.keys, LEVEL_KEYS, "level #{name}")
        percent = require_percent(attrs['budget_percent'], name)
        queues = {}
        QUEUE_NAMES.each do |queue|
          queues[queue] = parse_queue(attrs[queue], "#{name}.#{queue}")
        end
        @levels[name.to_s] = Level.new(
          name: name.to_s,
          budget_percent: percent,
          queues: queues,
          retry_size: optional_number(attrs['retry_size'], "#{name}.retry_size")
        )
      end
    end

    def parse_queue(raw, label)
      return {} if raw.nil?
      raise ArgumentError, "#{label} must be an object" unless raw.is_a?(Hash)

      attrs = stringify(raw)
      reject_unknown!(attrs.keys, QUEUE_FIELDS, label)
      QUEUE_FIELDS.each_with_object({}) do |field, memo|
        value = optional_number(attrs[field], "#{label}.#{field}")
        memo[field] = value unless value.nil?
      end
    end

    def parse_capacity(raw)
      return if raw.nil?
      raise ArgumentError, 'capacity must be an object' unless raw.is_a?(Hash)

      attrs = stringify(raw)
      reject_unknown!(attrs.keys, CAPACITY_KEYS, 'capacity')
      @capacity = Capacity.new(
        max_tick_claims: optional_number(attrs['max_tick_claims'], 'capacity.max_tick_claims', integer: true),
        per_push_thread: optional_number(attrs['per_push_thread'], 'capacity.per_push_thread', integer: true),
        per_pull_thread: optional_number(attrs['per_pull_thread'], 'capacity.per_pull_thread', integer: true)
      )
    end

    def parse_fallback(raw)
      raise ArgumentError, 'fallback is required for version 2' if raw.nil?
      raise ArgumentError, 'fallback must be an object' unless raw.is_a?(Hash)

      attrs = stringify(raw)
      reject_unknown!(attrs.keys, FALLBACK_KEYS, 'fallback')
      @fallback = Fallback.new(budget_percent: require_percent(attrs['budget_percent'], 'fallback'))
    end

    def validate_monotonicity!
      percents = LEVEL_NAMES.map { |name| @levels[name]&.budget_percent }.compact
      percents.each_cons(2) do |weaker, stronger|
        raise ArgumentError, 'stronger levels must not recommend more budget than weaker levels' if stronger > weaker
      end

      signals.each do |path, values|
        values.each_cons(2) do |weaker, stronger|
          raise ArgumentError, "threshold #{path} must be non-decreasing toward stronger levels" if stronger < weaker
        end
      end
    end

    def signals
      collected = Hash.new { |hash, key| hash[key] = [] }
      LEVEL_NAMES.each do |name|
        level = @levels[name]
        next unless level

        QUEUE_NAMES.each do |queue|
          QUEUE_FIELDS.each do |field|
            value = level.queues.dig(queue, field)
            collected["#{queue}.#{field}"] << value unless value.nil?
          end
        end
        collected['retry_size'] << level.retry_size unless level.retry_size.nil?
      end
      collected
    end

    def require_percent(value, name)
      number = optional_number(value, "#{name}.budget_percent", integer: true)
      raise ArgumentError, "#{name}.budget_percent is required" if number.nil?
      raise ArgumentError, "#{name}.budget_percent must be 0..100" unless (0..100).cover?(number)

      number
    end

    def optional_number(value, label, integer: false)
      return if value.nil?
      raise ArgumentError, "#{label} must be a number" unless value.is_a?(Numeric)
      raise ArgumentError, "#{label} must be non-negative" if value.negative?
      raise ArgumentError, "#{label} must be an integer" if integer && value != value.to_i

      integer ? value.to_i : value
    end

    def reject_unknown!(keys, allowed, label)
      unknown = keys.map(&:to_s) - allowed
      raise ArgumentError, "unknown #{label} keys: #{unknown.join(', ')}" if unknown.any?
    end

    def stringify(value)
      value.to_h.transform_keys(&:to_s)
    end

    def canonical_json
      payload = {
        'version' => @version,
        'levels' => LEVEL_NAMES.each_with_object({}) do |name, memo|
          level = @levels[name]
          next unless level

          memo[name] = {
            'budget_percent' => level.budget_percent,
            'queues' => level.queues,
            'retry_size' => level.retry_size,
          }
        end,
        'capacity' => {
          'max_tick_claims' => @capacity.max_tick_claims,
          'per_push_thread' => @capacity.per_push_thread,
          'per_pull_thread' => @capacity.per_pull_thread,
        },
      }
      payload['fallback'] = { 'budget_percent' => @fallback.budget_percent } if @fallback
      JSON.generate(payload)
    end
  end
end
