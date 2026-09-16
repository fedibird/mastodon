# frozen_string_literal: true

# Reconstructable Redis controller state for shadow adaptive remote pacing.
#
# This is NOT work state and is NOT mixed with RemoteRuntimeState.
# Flushing Redis does not lose pending targets. Learned-high rates are
# not restored; the next observation / shadow read starts at the
# conservative initial_cap. Adaptive caps remain <= the corresponding
# PR F fixed cap (hard ceiling) on every read and write.
#
# Keys use a versioned namespace separate from PR F:
#   follow_import:remote_adaptive:v1:destination:<destination_domain>
#   follow_import:remote_adaptive:v1:origin:<endpoint_origin>
#
# Origin values are privacy-safe EndpointOrigin only (scheme + host +
# non-default port). Inbox path/query is never stored. Missing
# destination_domain is never persisted as a synthetic key.
#
# One key transition is atomic (Lua). Destination and origin keys are
# independent; they do not share a distributed transaction. Concurrent
# DeliveryWorker events on the same key are serialized in Redis so an
# event cannot disappear via GET / Ruby / SET.
module FollowImport
  class AdaptiveRemoteState
    include Redisable

    SCHEMA_VERSION = FollowImport::AdaptiveRemoteController::SCHEMA_VERSION
    KEY_PREFIX = 'follow_import:remote_adaptive:v1'

    APPLY_LUA = <<~LUA.freeze
      local key = KEYS[1]
      local event = ARGV[1]
      local now = tonumber(ARGV[2])
      local stale_after = tonumber(ARGV[3])
      local ttl = tonumber(ARGV[4])
      local initial_cap = tonumber(ARGV[5])
      local min_cap = tonumber(ARGV[6])
      local additive_step = tonumber(ARGV[7])
      local successes_per_increase = tonumber(ARGV[8])
      local failure_pct = tonumber(ARGV[9])
      local rate_limit_pct = tonumber(ARGV[10])
      local ceiling = tonumber(ARGV[11])
      local adaptive_digest = ARGV[12]
      local fixed_digest = ARGV[13]
      local schema_version = tonumber(ARGV[14])
      local observed_at = ARGV[15]

      local function clamp(cap)
        if cap > ceiling then cap = ceiling end
        if cap < min_cap then cap = min_cap end
        return cap
      end

      local function initial(source)
        return {
          schema_version = schema_version,
          current_cap = clamp(initial_cap),
          success_credit = 0,
          observed_at = observed_at,
          observed_at_unix = now,
          adaptive_profile_digest = adaptive_digest,
          fixed_profile_digest = fixed_digest,
          source = source
        }
      end

      local source = 'initial'
      local state = initial('initial')
      local existing = redis.call('GET', key)
      if existing then
        local ok, data = pcall(cjson.decode, existing)
        if ok and type(data) == 'table' and tonumber(data['schema_version']) == schema_version then
          local observed = tonumber(data['observed_at_unix'])
          local stale = (observed == nil) or ((now - observed) > stale_after)
          local digest_ok = (data['adaptive_profile_digest'] == adaptive_digest)
            and (data['fixed_profile_digest'] == fixed_digest)
          if stale then
            source = 'stale_reset'
            state = initial('stale_reset')
          elseif not digest_ok then
            source = 'digest_reset'
            state = initial('digest_reset')
          else
            source = 'learned'
            state = data
            state['current_cap'] = clamp(tonumber(state['current_cap']) or initial_cap)
            state['success_credit'] = tonumber(state['success_credit']) or 0
            state['source'] = 'learned'
          end
        else
          source = 'corrupt_reset'
          state = initial('corrupt_reset')
        end
      end

      local before = tonumber(state['current_cap'])
      local cap = before
      local credit = tonumber(state['success_credit']) or 0

      if event == 'success' then
        credit = credit + 1
        while credit >= successes_per_increase do
          cap = cap + additive_step
          credit = credit - successes_per_increase
        end
      elseif event == 'rate_limit' then
        cap = math.floor(cap * rate_limit_pct / 100)
        credit = 0
      elseif event == 'failure' then
        cap = math.floor(cap * failure_pct / 100)
        credit = 0
      end

      cap = clamp(cap)
      state['current_cap'] = cap
      state['success_credit'] = credit
      state['observed_at'] = observed_at
      state['observed_at_unix'] = now
      state['adaptive_profile_digest'] = adaptive_digest
      state['fixed_profile_digest'] = fixed_digest
      state['schema_version'] = schema_version
      state['source'] = source

      redis.call('SET', key, cjson.encode(state), 'EX', ttl)

      return cjson.encode({
        cap_before = before,
        cap_after = cap,
        success_credit = credit,
        source = source
      })
    LUA

    LayerResult = Struct.new(:written, :cap_before, :cap_after, :source, :success_credit, keyword_init: true)
    ApplyResult = Struct.new(:destination, :origin, :written, keyword_init: true)

    attr_reader :adaptive_profile, :fixed_profile

    def initialize(adaptive_profile:, fixed_profile:, now: Time.now.utc)
      @adaptive_profile = adaptive_profile
      @fixed_profile = fixed_profile
      @now = now
      @available = true
    end

    def available?
      @available
    end

    def snapshot
      Snapshot.new(self)
    end

    def destination_key(destination_domain)
      "#{KEY_PREFIX}:destination:#{destination_domain}"
    end

    def origin_key(endpoint_origin)
      "#{KEY_PREFIX}:origin:#{endpoint_origin}"
    end

    def view_for_destination(destination_domain)
      return fallback_view(:destination, FollowImport::AdaptiveRemoteController::SOURCE_INITIAL) if destination_domain.blank?

      read_view(:destination, destination_domain)
    end

    def view_for_origin(endpoint_origin)
      return fallback_view(:origin, FollowImport::AdaptiveRemoteController::SOURCE_INITIAL) if endpoint_origin.blank?

      read_view(:origin, endpoint_origin)
    end

    # Apply one classified transport event to destination and/or origin.
    # Neutral events do not write. Missing destination is not persisted.
    # Write failures warn and return written=false; callers must not fail
    # delivery or the transport observation.
    def apply(destination_domain:, endpoint_origin:, event:)
      return ApplyResult.new(written: false) unless FollowImport::AdaptiveRemoteObservation.mutating?(event)

      dest_result = nil
      origin_result = nil

      if destination_domain.present? && !local_destination?(destination_domain)
        dest_result = apply_layer(:destination, destination_domain, event)
      end
      if endpoint_origin.present?
        origin_result = apply_layer(:origin, endpoint_origin, event)
      end

      ApplyResult.new(
        destination: dest_result,
        origin: origin_result,
        written: dest_result&.written || origin_result&.written || false
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('adaptive_remote_state_write', e)
      ApplyResult.new(written: false)
    end

    def fallback_view(layer, source)
      FollowImport::AdaptiveRemoteController.initial_view(
        layer_params(layer),
        now: @now,
        adaptive_digest: @adaptive_profile.digest,
        fixed_digest: @fixed_profile.digest,
        ceiling: ceiling_for(layer),
        source: source
      )
    end

    private

    def read_view(layer, key)
      return fallback_view(layer, FollowImport::AdaptiveRemoteController::SOURCE_RUNTIME_UNAVAILABLE) unless available?

      raw = redis.get(redis_key(layer, key))
      return fallback_view(layer, FollowImport::AdaptiveRemoteController::SOURCE_INITIAL) if raw.blank?

      FollowImport::AdaptiveRemoteController.view_from_payload(
        JSON.parse(raw),
        params: layer_params(layer),
        now: @now,
        stale_after: @adaptive_profile.stale_after_seconds,
        adaptive_digest: @adaptive_profile.digest,
        fixed_digest: @fixed_profile.digest,
        ceiling: ceiling_for(layer)
      )
    rescue Redis::BaseError, Redis::CannotConnectError => e
      mark_unavailable(e)
      fallback_view(layer, FollowImport::AdaptiveRemoteController::SOURCE_RUNTIME_UNAVAILABLE)
    rescue StandardError
      fallback_view(layer, FollowImport::AdaptiveRemoteController::SOURCE_CORRUPT_RESET)
    end

    def apply_layer(layer, key, event)
      payload = redis.eval(
        APPLY_LUA,
        keys: [redis_key(layer, key)],
        argv: apply_argv(layer, event)
      )
      data = JSON.parse(payload.to_s)
      LayerResult.new(
        written: true,
        cap_before: data['cap_before'].to_i,
        cap_after: data['cap_after'].to_i,
        source: data['source'].to_s,
        success_credit: data['success_credit'].to_i
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('adaptive_remote_state_write', e)
      LayerResult.new(written: false)
    end

    def apply_argv(layer, event)
      params = layer_params(layer)
      [
        event.to_s,
        @now.to_i,
        @adaptive_profile.stale_after_seconds,
        @adaptive_profile.state_ttl_seconds,
        params.initial_cap,
        params.min_cap,
        params.additive_step,
        params.successes_per_increase,
        params.failure_multiplier_percent,
        params.rate_limit_multiplier_percent,
        ceiling_for(layer),
        @adaptive_profile.digest,
        @fixed_profile.digest,
        SCHEMA_VERSION,
        @now.iso8601,
      ]
    end

    def redis_key(layer, key)
      layer.to_s == 'origin' ? origin_key(key) : destination_key(key)
    end

    def layer_params(layer)
      layer.to_s == 'origin' ? @adaptive_profile.origin : @adaptive_profile.destination
    end

    def ceiling_for(layer)
      if layer.to_s == 'origin'
        @fixed_profile.origin_per_tick_cap
      else
        @fixed_profile.destination_per_tick_cap
      end
    end

    def local_destination?(domain)
      return false if domain.blank?

      TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
    end

    def mark_unavailable(error)
      @available = false
      FollowImport::Telemetry.warn_failure('adaptive_remote_state_read', error)
    end

    # Per-tick memoized views. One destination with many planned rows
    # must not issue one Redis GET per candidate.
    class Snapshot
      def initialize(state)
        @state = state
        @destinations = {}
        @origins = {}
      end

      def available?
        @state.available?
      end

      def view_for_destination(destination_domain)
        return @state.fallback_view(:destination, FollowImport::AdaptiveRemoteController::SOURCE_INITIAL) if destination_domain.blank?
        return @destinations[destination_domain] if @destinations.key?(destination_domain)

        @destinations[destination_domain] = @state.view_for_destination(destination_domain)
      end

      def view_for_origin(endpoint_origin)
        return @state.fallback_view(:origin, FollowImport::AdaptiveRemoteController::SOURCE_INITIAL) if endpoint_origin.blank?
        return @origins[endpoint_origin] if @origins.key?(endpoint_origin)

        @origins[endpoint_origin] = @state.view_for_origin(endpoint_origin)
      end
    end
  end
end
