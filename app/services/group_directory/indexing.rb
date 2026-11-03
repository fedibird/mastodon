# frozen_string_literal: true

# Live updates for GroupDirectoryIndex.
#
# GROUP_DIRECTORY_INDEX=true and ES_ENABLED=true both have to be set. With
# either one off, hooks return before they touch Redis or Elasticsearch.
# The directory API does not read this index yet.
#
# Jobs carry account ids only. The worker loads the current rows and lets
# Chewy delete anything that is no longer listable, so a slow job cannot
# write a document that was built before a later commit.
#
# Ids are coalesced in a Redis set. One pull-queue job drains them in
# batches. A second enqueue while a drain is scheduled does not add another
# job. If the index has not been created, the ids stay in the set and the
# job does not retry in a loop; the next enqueue tries again after
# `tootctl search deploy --only group_directory`.
class GroupDirectory::Indexing
  PENDING_KEY = 'group_directory:index:pending'
  SCHEDULE_KEY = 'group_directory:index:scheduled'
  BATCH_SIZE = 100
  DOMAIN_BATCH = 500
  SCHEDULE_TTL = 120

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
    end

    def pop_batch
      Array(redis.spop(PENDING_KEY, BATCH_SIZE)).compact
    end

    def requeue(ids)
      ids = normalize_ids(ids)
      redis.sadd(PENDING_KEY, ids) if ids.any?
    end

    def schedule!
      return unless redis.set(SCHEDULE_KEY, '1', nx: true, ex: SCHEDULE_TTL)

      GroupDirectoryIndexWorker.perform_async
    end

    def continue!
      if pending?
        GroupDirectoryIndexWorker.perform_async
      else
        release_if_idle!
      end
    end

    def release_if_idle!
      redis.del(SCHEDULE_KEY)
      schedule! if pending?
    end

    def release_schedule!
      redis.del(SCHEDULE_KEY)
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
      Array(account_ids).flatten.compact.map(&:to_i).select(&:positive?).uniq
    end

    def defer_until_commit?
      connection = ActiveRecord::Base.connection
      connection.transaction_open?
    end
  end

  # Registered on the open transaction. committed! runs after the outermost
  # commit, which is also when model after_commit hooks run. A rollback
  # drops the ids.
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
