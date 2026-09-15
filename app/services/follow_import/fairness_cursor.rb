# frozen_string_literal: true

# Reconstructable shadow fairness cursor. Not business/work state.
#
# Redis is an optimization so successive shadow ticks rotate owners/batches.
# Losing it only resets to stable DB order (owner_key, batch_id). It must
# never duplicate or lose Follow Import work, change plan budget, or fail
# the real executor. Claims stay on follow_import_targets.
#
# A durable DB dispatcher-state row is not added: the cursor is
# reconstructable, TTL-bounded, and Redis is already used for failure-
# tolerant Follow Import telemetry. Single-flight correctness remains the
# PostgreSQL advisory lease.
module FollowImport
  class FairnessCursor
    include Redisable

    KEY        = 'follow_import:dispatch:shadow_fairness'
    TTL        = 7.days.to_i
    MAX_OWNERS = 500
    MAX_BATCHES = 2_000

    SOURCE_REDIS          = 'redis'
    SOURCE_DEFAULT        = 'default'
    SOURCE_RESET          = 'reset'
    SOURCE_PERSIST_FAILED = 'persist_failed'

    State = Struct.new(:last_owner_key, :last_batch_by_owner, :last_position_by_batch, :source, keyword_init: true) do
      def self.empty(source: FollowImport::FairnessCursor::SOURCE_DEFAULT)
        new(last_owner_key: nil, last_batch_by_owner: {}, last_position_by_batch: {}, source: source)
      end
    end

    def read
      raw = redis.get(KEY)
      return State.empty(source: SOURCE_DEFAULT) if raw.blank?

      parse(raw)
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('fairness_cursor_read', e)
      State.empty(source: SOURCE_RESET)
    end

    def write(state)
      payload = JSON.generate(
        'last_owner_key' => state.last_owner_key,
        'last_batch_by_owner' => trim_hash(state.last_batch_by_owner, MAX_OWNERS),
        'last_position_by_batch' => trim_hash(state.last_position_by_batch, MAX_BATCHES)
      )
      redis.set(KEY, payload, ex: TTL)
      true
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('fairness_cursor_write', e)
      false
    end

    private

    def parse(raw)
      data = JSON.parse(raw)
      State.new(
        last_owner_key: data['last_owner_key'],
        last_batch_by_owner: stringify_keys(data['last_batch_by_owner']),
        last_position_by_batch: stringify_keys(data['last_position_by_batch']),
        source: SOURCE_REDIS
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('fairness_cursor_parse', e)
      State.empty(source: SOURCE_RESET)
    end

    def stringify_keys(value)
      return {} unless value.is_a?(Hash)

      value.transform_keys(&:to_s)
    end

    def trim_hash(hash, max)
      hash.to_a.last(max).to_h
    end
  end
end
