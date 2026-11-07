# frozen_string_literal: true

# Live updates for GroupDirectoryIndex.
#
# GROUP_DIRECTORY_INDEX=true and ES_ENABLED=true both have to be set. With
# either one off, hooks return before they touch Redis or Elasticsearch.
# The directory API reads this index only when GROUP_DIRECTORY_ES_SEARCH
# is also on. That flag defaults off. A version gap makes that read fail
# closed instead of serving the SQL listing.
#
# Jobs carry no document. A worker claims ids atomically from the pending
# set into an inflight sorted set, imports the current rows, then acks.
# Chewy deletes anything that is no longer listable. A kill before ack
# leaves the ids inflight; the lease and the minute scheduler put them
# back on pending. Redis errors while enqueueing are logged and do not
# raise, so a committed request is not turned into a 500. A normal
# `tootctl search deploy` only adds rows. It does not delete a document
# whose enqueue never reached Redis. That needs
# `tootctl search deploy --only group_directory --rebuild`.
class GroupDirectory::Indexing
  PENDING_KEY = 'group_directory:index:pending'
  INFLIGHT_KEY = 'group_directory:index:inflight'
  CLAIM_SEQ_KEY = 'group_directory:index:claim_seq'
  VERSIONS_KEY = 'group_directory:index:versions'
  VERSION_GAP_KEY = 'group_directory:index:version_gap'
  # Set only after Import.rebuild! finishes. An index that merely exists
  # can still be empty or half loaded. Search stays closed until this is set.
  BACKFILL_KEY = 'group_directory:index:backfill_complete'
  SCHEDULE_KEY = 'group_directory:index:scheduled'
  BATCH_SIZE = 100
  DOMAIN_BATCH = 500
  RECLAIM_LIMIT = 500
  SCHEDULE_TTL = 120
  INFLIGHT_LEASE = 300

  # Members are "account_id:token". Ack and return name that member, so a
  # late ack cannot delete a newer claim of the same account.
  CLAIM_SCRIPT = <<~LUA
    local function empty(value)
      return value == false or value == nil
    end
    local ids = redis.call('SPOP', KEYS[1], tonumber(ARGV[1]))
    if empty(ids) then
      return {}
    end
    if type(ids) ~= 'table' then
      ids = { ids }
    end
    local now = tonumber(ARGV[2])
    local members = {}
    for i = 1, #ids do
      local token = redis.call('INCR', KEYS[3])
      local member = ids[i] .. ':' .. token
      redis.call('ZADD', KEYS[2], now, member)
      members[i] = member
    end
    return members
  LUA

  ACK_SCRIPT = <<~LUA
    for i = 1, #ARGV do
      redis.call('ZREM', KEYS[1], ARGV[i])
    end
    return #ARGV
  LUA

  RETURN_SCRIPT = <<~LUA
    local function account_id(member)
      return string.match(member, '^(%d+):%d+$')
    end
    for i = 1, #ARGV do
      local id = account_id(ARGV[i])
      if id then
        redis.call('ZREM', KEYS[1], ARGV[i])
        redis.call('SADD', KEYS[2], id)
      end
    end
    return #ARGV
  LUA

  RECLAIM_SCRIPT = <<~LUA
    local function account_id(member)
      return string.match(member, '^(%d+):%d+$')
    end
    local members = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, tonumber(ARGV[2]))
    local ids = {}
    for i = 1, #members do
      local id = account_id(members[i])
      if id then
        redis.call('ZREM', KEYS[1], members[i])
        redis.call('SADD', KEYS[2], id)
        ids[#ids + 1] = id
      end
    end
    return ids
  LUA

  # Pending membership and the version counter are updated in one script
  # so a claim cannot see the id at the previous version. Redis does not roll
  # back a script that errors after a write. The type check runs first, so a
  # wrong key type fails before either write. An error after SADD, such as
  # the instance running out of memory, can still leave the id queued.
  ENQUEUE_SCRIPT = <<~LUA
    local pending_type = redis.call('TYPE', KEYS[1])['ok']
    if pending_type ~= 'none' and pending_type ~= 'set' then
      return redis.error_reply('WRONGTYPE ' .. KEYS[1] .. ' is ' .. pending_type)
    end
    local version_type = redis.call('TYPE', KEYS[2])['ok']
    if version_type ~= 'none' and version_type ~= 'hash' then
      return redis.error_reply('WRONGTYPE ' .. KEYS[2] .. ' is ' .. version_type)
    end
    -- Validate every field before any write. A non-integer field makes
    -- HINCRBY fail, and Redis does not undo an earlier SADD in this script.
    for i = 1, #ARGV do
      local current = redis.call('HGET', KEYS[2], ARGV[i])
      if current ~= false and string.match(tostring(current), '^-?%d+$') == nil then
        return redis.error_reply('WRONGTYPE version field ' .. ARGV[i])
      end
    end
    for i = 1, #ARGV do
      redis.call('SADD', KEYS[1], ARGV[i])
      redis.call('HINCRBY', KEYS[2], ARGV[i], 1)
    end
    return #ARGV
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

      redis.eval(ENQUEUE_SCRIPT, keys: [PENDING_KEY, VERSIONS_KEY], argv: ids)
      schedule!
    rescue StandardError => e
      log_enqueue_failure(ids, e)
      nil
    end

    # Pending id -> inflight member "id:token", in one Redis script.
    def claim_batch
      claimed = redis.eval(CLAIM_SCRIPT, keys: [PENDING_KEY, INFLIGHT_KEY, CLAIM_SEQ_KEY], argv: [BATCH_SIZE, Time.now.to_i])
      Array(claimed).compact
    end

    def account_id(member)
      member.to_s.split(':', 2).first
    end

    def ack(members)
      members = normalize_members(members)
      return if members.empty?

      redis.eval(ACK_SCRIPT, keys: [INFLIGHT_KEY], argv: members)
    end

    # Failed attempt. Only this claim is removed; a newer claim is left alone.
    def return_to_pending(members)
      members = normalize_members(members)
      return if members.empty?

      redis.eval(RETURN_SCRIPT, keys: [INFLIGHT_KEY, PENDING_KEY], argv: members)
    end

    def reclaim_expired!(now = Time.now.to_i, limit: RECLAIM_LIMIT)
      cutoff = now - INFLIGHT_LEASE
      reclaimed = redis.eval(RECLAIM_SCRIPT, keys: [INFLIGHT_KEY, PENDING_KEY], argv: [cutoff, limit])
      Array(reclaimed).compact
    end

    # A claim may be written only while its member is still inflight and
    # younger than the lease. Reclaim does not stop a worker by itself.
    def claims_writable?(members, now = Time.now.to_i)
      members = normalize_members(members)
      return false if members.empty?

      members.all? do |member|
        score = redis.zscore(INFLIGHT_KEY, member)
        score && now.to_i - score.to_i < INFLIGHT_LEASE
      end
    end

    def quarantine_version_gap(members)
      members = normalize_members(members)
      ids = members.map { |member| account_id(member) }.uniq
      redis.sadd(VERSION_GAP_KEY, ids) if ids.any?
      redis.eval(ACK_SCRIPT, keys: [INFLIGHT_KEY], argv: members) if members.any?
    end

    def clear_version_gap!
      redis.del(VERSION_GAP_KEY)
    end

    def version_gap?
      redis.scard(VERSION_GAP_KEY).to_i.positive?
    end

    def mark_backfill_complete!
      redis.set(BACKFILL_KEY, Time.now.to_i.to_s)
    end

    def clear_backfill_complete!
      redis.del(BACKFILL_KEY)
    end

    def backfill_complete?
      redis.exists?(BACKFILL_KEY)
    end

    # A mapping upgrade purges the index. Drop the ready marker first so a
    # failed refill cannot keep serving the old "complete" flag.
    def before_index_purge!(index)
      return false unless index == GroupDirectoryIndex

      clear_backfill_complete!
      true
    end

    # A --min/--max import does not see every group. Leave the marker clear
    # so a bounded upgrade cannot turn search on over a partial index.
    def complete_index_upgrade!(upgraded, bounded:)
      return unless upgraded
      return if bounded

      mark_backfill_complete!
    end

    def each_outstanding_batch(limit: BATCH_SIZE, &block)
      scan_ids(PENDING_KEY, limit, &block)
      scan_inflight_ids(limit, &block)
    end

    # Minute scheduler entry. Also used when Sidekiq gives up on a drain.
    def recover!
      return unless live_sync_enabled?

      reclaim_expired!
      if version_gap?
        Rails.logger.error('Group directory index has a Redis/Elasticsearch version gap. Run tootctl search deploy --only group_directory --rebuild')
      end
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

    def normalize_members(members)
      Array(members).flatten.compact.map(&:to_s).select { |member| member.match?(/\A\d+:\d+\z/) }.uniq
    end

    def scan_ids(key, limit, &block)
      cursor = '0'
      loop do
        cursor, ids = redis.sscan(key, cursor, count: limit)
        Array(ids).each_slice(limit, &block)
        break if cursor.to_s == '0'
      end
    end

    def scan_inflight_ids(limit, &block)
      cursor = '0'
      loop do
        cursor, pairs = redis.zscan(INFLIGHT_KEY, cursor, count: limit)
        ids = Array(pairs).map { |member, _score| account_id(member) }.uniq
        ids.each_slice(limit, &block)
        break if cursor.to_s == '0'
      end
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
