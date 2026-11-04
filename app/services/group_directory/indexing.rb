# frozen_string_literal: true

# Live updates for GroupDirectoryIndex.
#
# GROUP_DIRECTORY_INDEX=true and ES_ENABLED=true both have to be set. With
# either one off, hooks return before they touch Redis or Elasticsearch.
# The directory API does not read this index yet.
#
# Jobs carry no document. A worker claims ids atomically from the pending
# set into an inflight sorted set, imports the current rows, then acks.
# Chewy deletes anything that is no longer listable. A kill before ack
# leaves the ids inflight; the lease and the minute scheduler put them
# back on pending. Redis errors while enqueueing are logged and do not
# raise, so a committed request is not turned into a 500. Ids that never
# reached Redis are recovered by `tootctl search deploy --only group_directory`.
class GroupDirectory::Indexing
  PENDING_KEY = 'group_directory:index:pending'
  INFLIGHT_KEY = 'group_directory:index:inflight'
  SCHEDULE_KEY = 'group_directory:index:scheduled'
  BATCH_SIZE = 100
  DOMAIN_BATCH = 500
  SCHEDULE_TTL = 120
  INFLIGHT_LEASE = 300

  CLAIM_SCRIPT = <<~LUA
    local ids = redis.call('SPOP', KEYS[1], tonumber(ARGV[1]))
    if ids == false or ids == nil then
      return {}
    end
    if type(ids) ~= 'table' then
      ids = { ids }
    end
    local now = tonumber(ARGV[2])
    for i = 1, #ids do
      redis.call('ZADD', KEYS[2], now, ids[i])
    end
    return ids
  LUA

  ACK_SCRIPT = <<~LUA
    for i = 1, #ARGV do
      redis.call('ZREM', KEYS[1], ARGV[i])
    end
    return #ARGV
  LUA

  RETURN_SCRIPT = <<~LUA
    for i = 1, #ARGV do
      redis.call('ZREM', KEYS[1], ARGV[i])
      redis.call('SADD', KEYS[2], ARGV[i])
    end
    return #ARGV
  LUA

  RECLAIM_SCRIPT = <<~LUA
    local ids = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
    for i = 1, #ids do
      redis.call('ZREM', KEYS[1], ids[i])
      redis.call('SADD', KEYS[2], ids[i])
    end
    return ids
  LUA

  class << self
    include Redisable

    def live_sync_enabled?
      Chewy.enabled? && ActiveModel::Type::Boolean.new.cast(ENV['GROUP_DIRECTORY_INDEX'])
    end

    def enqueue(account_ids)
      ids = normalize_ids(account_ids)
      return if ids.empty?
      return unless live_sync_enabled?

      if defer_until_commit?
        ActiveRecord::Base.connection.add_transaction_record(CommitRequest.new(ids))
      else
        push(ids)
      end
    rescue StandardError => e
      log_enqueue_failure(ids, e)
      nil
    end

    def enqueue_domain(domain)
      return unless live_sync_enabled?
      return if domain.blank?

      Account.groups.where(domain: domain).in_batches(of: DOMAIN_BATCH) do |batch|
        enqueue(batch.pluck(:id))
      end
    end

    def push(ids)
      ids = normalize_ids(ids)
      return if ids.empty?
      return unless live_sync_enabled?

      redis.sadd(PENDING_KEY, ids)
      schedule!
    rescue StandardError => e
      log_enqueue_failure(ids, e)
      nil
    end

    # Pending id -> inflight, in one Redis script. A crash after this returns
    # still has the ids in the inflight set.
    def claim_batch
      claimed = redis.eval(CLAIM_SCRIPT, keys: [PENDING_KEY, INFLIGHT_KEY], argv: [BATCH_SIZE, Time.now.to_i])
      Array(claimed).compact
    end

    def ack(ids)
      ids = normalize_ids(ids)
      return if ids.empty?

      redis.eval(ACK_SCRIPT, keys: [INFLIGHT_KEY], argv: ids)
    end

    # Failed attempt: inflight membership and pending membership move together.
    def return_to_pending(ids)
      ids = normalize_ids(ids)
      return if ids.empty?

      redis.eval(RETURN_SCRIPT, keys: [INFLIGHT_KEY, PENDING_KEY], argv: ids)
    end

    def reclaim_expired!(now = Time.now.to_i)
      cutoff = now - INFLIGHT_LEASE
      reclaimed = redis.eval(RECLAIM_SCRIPT, keys: [INFLIGHT_KEY, PENDING_KEY], argv: [cutoff])
      Array(reclaimed).compact
    end

    # Minute scheduler entry. Also used when Sidekiq gives up on a drain.
    def recover!
      return unless live_sync_enabled?

      reclaim_expired!
      return unless pending?
      return unless index_ready?

      schedule!
    rescue StandardError => e
      Rails.logger.error("Group directory index recovery failed: #{e.class}: #{e.message}")
      nil
    end

    def schedule!
      return unless live_sync_enabled?
      return unless redis.set(SCHEDULE_KEY, '1', nx: true, ex: SCHEDULE_TTL)

      GroupDirectoryIndexWorker.perform_async
    rescue StandardError => e
      Rails.logger.error("Group directory index schedule failed: #{e.class}: #{e.message}")
      release_schedule!
      nil
    end

    def touch_schedule!
      redis.set(SCHEDULE_KEY, '1', ex: SCHEDULE_TTL)
    rescue StandardError
      nil
    end

    def continue!
      if pending?
        GroupDirectoryIndexWorker.perform_async
      else
        release_if_idle!
      end
    rescue StandardError => e
      Rails.logger.error("Group directory index reschedule failed: #{e.class}: #{e.message}")
      release_schedule!
      nil
    end

    def release_if_idle!
      redis.del(SCHEDULE_KEY)
      schedule! if pending?
    rescue StandardError => e
      Rails.logger.error("Group directory index idle release failed: #{e.class}: #{e.message}")
      nil
    end

    def release_schedule!
      redis.del(SCHEDULE_KEY)
    rescue StandardError
      nil
    end

    def pending?
      redis.scard(PENDING_KEY).to_i.positive?
    end

    def index_ready?
      Chewy.client.indices.exists?(index: GroupDirectoryIndex.index_name)
    rescue StandardError => e
      Rails.logger.error("Group directory index check failed: #{e.class}: #{e.message}")
      false
    end

    private

    def normalize_ids(account_ids)
      Array(account_ids).flatten.compact.map { |id| id.to_i.to_s }.select { |id| id.to_i.positive? }.uniq
    end

    def defer_until_commit?
      ActiveRecord::Base.connection.transaction_open?
    end

    def log_enqueue_failure(ids, error)
      Rails.logger.error("Group directory index enqueue failed for #{Array(ids).size} accounts: #{error.class}: #{error.message}")
    end
  end

  # Registered on the open transaction. committed! runs after the outermost
  # commit. A rollback drops the ids. push swallows Redis errors.
  class CommitRequest
    def initialize(ids)
      @ids = ids
    end

    def committed!(should_run_callbacks: true)
      GroupDirectory::Indexing.push(@ids) if should_run_callbacks
    end

    def rolledback!(**_options)
      # A rolled back save must not leave ids for the worker.
    end

    def before_committed!
      # Nothing to flush before the database commit.
    end

    def trigger_transactional_callbacks?
      true
    end
  end
end
