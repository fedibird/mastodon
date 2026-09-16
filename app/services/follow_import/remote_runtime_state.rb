# frozen_string_literal: true

# Reconstructable Redis observations for fixed remote admission.
#
# This is NOT work state. Flushing Redis does not lose pending targets.
# Mapping and suppression become unknown; the configured destination
# first-contact cap must still apply.
#
# Keys use a versioned namespace:
#   follow_import:remote_admission:v1:mapping:<destination_domain>
#   follow_import:remote_admission:v1:suppression:<endpoint_origin>
#
# Mapping value is privacy-safe EndpointOrigin only (scheme + host +
# non-default port). Inbox path/query is never stored. TTL comes only
# from the configured profile. Changing profile numbers does not require
# deleting work rows; new writes use the new TTL.
module FollowImport
  class RemoteRuntimeState
    include Redisable

    SCHEMA_VERSION = 1
    KEY_PREFIX = 'follow_import:remote_admission:v1'

    # Atomic max(existing, proposed) across DeliveryWorker processes.
    # A GET/compare/SET pair can lose a longer honor_until when two
    # writers both read the old value; this Lua script keeps the later
    # timestamp and sets TTL from that final value.
    EXTEND_SUPPRESSION_LUA = <<~LUA.freeze
      local key = KEYS[1]
      local payload = ARGV[1]
      local new_until = tonumber(ARGV[2])
      local new_ttl = tonumber(ARGV[3])
      local now = tonumber(ARGV[4])

      local existing = redis.call('GET', key)
      if existing then
        local ok, data = pcall(cjson.decode, existing)
        if ok and type(data) == 'table' then
          local existing_until = tonumber(data['honor_until_unix'])
          if existing_until and existing_until >= new_until then
            local remain = existing_until - now
            if remain < 1 then remain = 1 end
            redis.call('EXPIRE', key, remain)
            return existing
          end
        end
      end

      redis.call('SET', key, payload, 'EX', new_ttl)
      return payload
    LUA

    Mapping = Struct.new(:endpoint_origin, :observed_at, keyword_init: true)
    Suppression = Struct.new(:honor_until, :reason, :observed_at, keyword_init: true)

    attr_reader :profile

    def initialize(profile:, now: Time.now.utc)
      @profile = profile
      @now = now
      @available = true
    end

    def available?
      @available
    end

    def snapshot
      Snapshot.new(self)
    end

    def mapping_for(destination_domain)
      return unless available?
      return if destination_domain.blank?

      raw = redis.get(mapping_key(destination_domain))
      parse_mapping(raw)
    rescue StandardError => e
      mark_unavailable(e)
      nil
    end

    def suppression_for(endpoint_origin)
      return unless available?
      return if endpoint_origin.blank?

      raw = redis.get(suppression_key(endpoint_origin))
      parse_suppression(raw)
    rescue StandardError => e
      mark_unavailable(e)
      nil
    end

    # Write mapping / Retry-After / recent-429 from an actual HTTP attempt.
    # Returns true when at least one key was written. Failures warn and
    # return false; callers must not fail delivery or telemetry.
    def observe(destination_domain:, inbox_url:, http_status:, retry_after_seconds:, request_reached:)
      return false unless profile&.configured?
      return false unless request_reached

      origin = FollowImport::EndpointOrigin.from_url(inbox_url)
      written = false

      if destination_domain.present? && origin.present?
        write_mapping(destination_domain, origin)
        written = true
      end

      if origin.present?
        write_suppression(origin, http_status, retry_after_seconds)
        written = true
      end

      written
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('remote_runtime_state_write', e)
      false
    end

    def mapping_key(destination_domain)
      "#{KEY_PREFIX}:mapping:#{destination_domain}"
    end

    def suppression_key(endpoint_origin)
      "#{KEY_PREFIX}:suppression:#{endpoint_origin}"
    end

    private

    def write_mapping(destination_domain, origin)
      payload = JSON.generate(
        'schema_version' => SCHEMA_VERSION,
        'endpoint_origin' => origin,
        'observed_at' => @now.iso8601
      )
      redis.set(mapping_key(destination_domain), payload, ex: profile.mapping_ttl_seconds)
    end

    def write_suppression(origin, http_status, retry_after_seconds)
      honor_until, reason = next_honor(http_status, retry_after_seconds)
      return if honor_until.nil?

      honor_unix = honor_until.to_i
      payload = JSON.generate(
        'schema_version' => SCHEMA_VERSION,
        'honor_until' => honor_until.iso8601,
        'honor_until_unix' => honor_unix,
        'reason' => reason,
        'observed_at' => @now.iso8601
      )
      ttl = [(honor_unix - @now.to_i), 1].max
      redis.eval(
        EXTEND_SUPPRESSION_LUA,
        keys: [suppression_key(origin)],
        argv: [payload, honor_unix, ttl, @now.to_i]
      )
    end

    def next_honor(http_status, retry_after_seconds)
      unless retry_after_seconds.nil?
        capped = [retry_after_seconds.to_i, profile.max_retry_after_seconds].min
        return [nil, nil] unless capped.positive?

        return [@now + capped, 'retry_after']
      end

      return unless http_status.to_i == 429

      cooldown = profile.recent_429_cooldown_seconds
      return unless cooldown.positive?

      [@now + cooldown, 'recent_429']
    end

    def parse_mapping(raw)
      return if raw.blank?

      data = JSON.parse(raw)
      return unless data.is_a?(Hash)
      return unless data['schema_version'].to_i == SCHEMA_VERSION

      origin = data['endpoint_origin'].to_s.presence
      return if origin.blank?

      observed_at = parse_time(data['observed_at'])
      return if stale_mapping?(observed_at)

      Mapping.new(endpoint_origin: origin, observed_at: observed_at)
    rescue StandardError
      nil
    end

    def parse_suppression(raw)
      return if raw.blank?

      data = JSON.parse(raw)
      return unless data.is_a?(Hash)
      return unless data['schema_version'].to_i == SCHEMA_VERSION

      honor_until = parse_time(data['honor_until'])
      honor_until ||= parse_unix(data['honor_until_unix'])
      return if honor_until.nil? || honor_until <= @now

      Suppression.new(
        honor_until: honor_until,
        reason: data['reason'].to_s.presence,
        observed_at: parse_time(data['observed_at'])
      )
    rescue StandardError
      nil
    end

    def stale_mapping?(observed_at)
      return false if observed_at.nil?

      observed_at + profile.mapping_ttl_seconds < @now
    end

    def parse_time(value)
      return if value.blank?
      return value if value.is_a?(Time)

      Time.iso8601(value.to_s)
    rescue StandardError
      nil
    end

    def parse_unix(value)
      return if value.blank?

      Time.at(value.to_i).utc
    rescue StandardError
      nil
    end

    def mark_unavailable(error)
      @available = false
      FollowImport::Telemetry.warn_failure('remote_runtime_state_read', error)
    end

    # Per-tick memoized view. One destination with 1_000 rows must not
    # issue 1_000 identical Redis GETs.
    class Snapshot
      def initialize(state)
        @state = state
        @mappings = {}
        @suppressions = {}
      end

      def available?
        @state.available?
      end

      def mapping_for(destination_domain)
        return if destination_domain.blank?
        return @mappings[destination_domain] if @mappings.key?(destination_domain)

        @mappings[destination_domain] = @state.mapping_for(destination_domain)
      end

      def suppression_for(endpoint_origin)
        return if endpoint_origin.blank?
        return @suppressions[endpoint_origin] if @suppressions.key?(endpoint_origin)

        @suppressions[endpoint_origin] = @state.suppression_for(endpoint_origin)
      end
    end
  end
end
