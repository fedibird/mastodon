# frozen_string_literal: true

# Redis-only observation for one public post from an allow-listed local
# admin to one saved remote Group actor. This is not a delivery result,
# a remote acceptance signal, or a community-listing check.
#
# The record is created before the group inbox job is enqueued. HTTP 2xx
# evidence is monotonic. A later retry, a duplicate job, or a stale
# result does not clear it. Redis errors are swallowed by callers that
# must not fail ActivityPub delivery.
class PostingContext::GroupFederationObservation
  SCHEMA_VERSION = 1
  TTL = 14.days.to_i
  KEY_PATTERN = /\Agroup-post-observation:v1:status:(\d+):target:(\d+)\z/
  OPTION = 'group_delivery_observation'

  class << self
    def enabled?
      ENV['GROUP_FEDERATION_OBSERVATION_ENABLED'] == 'true'
    end

    def author_ids
      ENV.fetch('GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS', '').split(/[,\s]+/).filter_map do |part|
        next if part.blank?

        Integer(part, 10)
      rescue ArgumentError
        nil
      end.uniq
    end

    def author_allowed?(account)
      ids = author_ids
      return false if ids.empty? || account.nil? || !ids.include?(account.id)

      account.user&.admin?
    end

    def key_for(status_id, target_account_id)
      "group-post-observation:v1:status:#{status_id}:target:#{target_account_id}"
    end

    def valid_key?(key)
      key.is_a?(String) && KEY_PATTERN.match?(key)
    end

    # Returns the opaque observation id, or nil when this delivery must
    # not be observed. Does not mark the queue job as enqueued.
    def prepare(status, author)
      return unless enabled?
      return unless observable_status?(status, author)

      group = status.audience_account
      return unless remote_saved_group?(group)

      key = key_for(status.id, group.id)
      write_initial(key, status, group)
      key
    rescue StandardError => e
      warn_failure(e)
      nil
    end

    def mark_queued(key)
      return if key.blank?
      return unless valid_key?(key)

      eval_merge(key, 'queue', nil)
    rescue StandardError => e
      warn_failure(e)
      nil
    end

    def apply_attempt(key, event)
      return unless valid_key?(key)

      eval_merge(key, 'attempt', JSON.generate(event))
    rescue StandardError => e
      warn_failure(e)
      nil
    end

    def mark_terminal(key)
      return unless valid_key?(key)

      eval_merge(key, 'terminal', nil)
    rescue StandardError => e
      warn_failure(e)
      nil
    end

    def read(status_id, target_account_id)
      key = key_for(status_id, target_account_id)
      raw = RedisConfiguration.with { |redis| redis.get(key) }
      return if raw.blank?

      JSON.parse(raw)
    rescue StandardError => e
      warn_failure(e)
      nil
    end

    private

    def observable_status?(status, author)
      status.present? &&
        status.public_visibility? &&
        status.local? &&
        !status.reblog? &&
        author.present? &&
        author.local? &&
        author_allowed?(author)
    end

    def remote_saved_group?(group)
      group.present? &&
        group.group? &&
        !group.local? &&
        group.activitypub? &&
        group.id.present? &&
        group.uri.present? &&
        group.inbox_url.present?
    end

    def write_initial(key, status, group)
      payload = JSON.generate(initial_payload(status, group))
      RedisConfiguration.with do |redis|
        redis.set(key, payload, nx: true, ex: TTL)
      end
    end

    def initial_payload(status, group)
      {
        'schema_version' => SCHEMA_VERSION,
        'status_id' => status.id.to_s,
        'target_account_id' => group.id.to_s,
        'adapter' => adapter_name_for(group),
        'activity_type' => 'Create',
        'queue_observed' => false,
        'attempt_count' => 0,
        'last_http_status' => nil,
        'http_2xx_observed' => false,
        'http_2xx_at' => '',
        'last_attempt_outcome' => 'not_attempted',
        'terminal_failure' => false,
        'last_request_started_at' => '',
      }
    end

    def adapter_name_for(group)
      PostingContext::DiscoveryService::ADAPTERS.find { |adapter| adapter.applicable?(group) }&.adapter_name
    end

    def eval_merge(key, mode, event_json)
      RedisConfiguration.with do |redis|
        redis.eval(MERGE_SCRIPT, keys: [key], argv: [mode, TTL.to_s, event_json.to_s])
      end
    end

    def warn_failure(error)
      Rails.logger.warn("[PostingContext::GroupFederationObservation] #{error.class}")
    end
  end

  # Atomic merge. A missing key stays missing. HTTP 2xx is sticky.
  # An older request_started_at cannot replace a newer last outcome.
  MERGE_SCRIPT = <<~LUA
    local key = KEYS[1]
    local mode = ARGV[1]
    local ttl = tonumber(ARGV[2])
    local raw = redis.call('GET', key)
    if not raw then
      return nil
    end

    local data = cjson.decode(raw)

    local function blank(value)
      return value == nil or value == cjson.null or value == ''
    end

    if mode == 'queue' then
      data['queue_observed'] = true
    elseif mode == 'terminal' then
      data['terminal_failure'] = true
    elseif mode == 'attempt' then
      local event = cjson.decode(ARGV[3])
      if event['http_attempt'] then
        data['attempt_count'] = (tonumber(data['attempt_count']) or 0) + 1
      end

      if event['http_2xx'] then
        data['http_2xx_observed'] = true
        if blank(data['http_2xx_at']) then
          data['http_2xx_at'] = event['observed_at']
        end
      end

      local stored = data['last_request_started_at']
      local incoming = event['request_started_at']
      local apply = true
      if not event['http_attempt'] and not blank(stored) then
        apply = false
      elseif not blank(stored) and blank(incoming) then
        apply = false
      elseif not blank(stored) and not blank(incoming) and incoming < stored then
        apply = false
      end

      if apply then
        data['last_attempt_outcome'] = event['outcome']
        if event['http_attempt'] then
          if event['http_status'] == nil or event['http_status'] == cjson.null then
            data['last_http_status'] = cjson.null
          else
            data['last_http_status'] = event['http_status']
          end
        end
        if not blank(incoming) then
          data['last_request_started_at'] = incoming
        end
      end
    end

    local encoded = cjson.encode(data)
    redis.call('SET', key, encoded, 'EX', ttl)
    return encoded
  LUA
end
