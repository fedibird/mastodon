# frozen_string_literal: true

# Reconstructable fairness cursor. Not a claim ledger.
#
# Redis is an optimization so successive ticks rotate owners/batches.
# Losing it only resets to stable DB order (owner_key, batch_id). It must
# never duplicate or lose Follow Import work, change plan budget, or stand
# in for follow_import_targets.state. Claims stay on those rows.
#
# The cursor advances as the planner *inspects* a pending row, including
# rows later skipped as unrecoverable/stale. That prevents a permanently
# unrecoverable first row from head-of-line blocking later work. An
# unclaimed pending row is not completed: wrap/rebuild (PendingTargetFeed
# wrap, Redis loss) makes it discoverable again.
#
# Bound: persist cursor entries for the currently-active owner/batch set
# and prune inactive ones. Do not apply an arbitrary MAX_OWNERS trim that
# can evict an active owner's last-batch pointer before its next turn.
# Redis loss may reset fairness temporarily; routine eviction of active
# fairness state must not.
#
# A durable DB dispatcher-state row is not added. Single-flight
# correctness remains the PostgreSQL advisory lease.
module FollowImport
  class FairnessCursor
    include Redisable

    KEY = 'follow_import:dispatch:shadow_fairness'
    TTL = 7.days.to_i

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

    def write(state, active_owner_keys: nil, active_batch_ids: nil)
      last_batch = stringify_keys(state.last_batch_by_owner)
      last_position = stringify_keys(state.last_position_by_batch)
      last_batch = last_batch.slice(*active_owner_keys.map(&:to_s)) unless active_owner_keys.nil?
      last_position = last_position.slice(*active_batch_ids.map(&:to_s)) unless active_batch_ids.nil?

      payload = JSON.generate(
        'last_owner_key' => state.last_owner_key,
        'last_batch_by_owner' => last_batch,
        'last_position_by_batch' => last_position
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
  end
end
