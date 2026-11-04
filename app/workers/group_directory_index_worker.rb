# frozen_string_literal: true

class GroupDirectoryIndexWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 5

  sidekiq_retries_exhausted do |_msg, exception|
    Rails.logger.error("Group directory index worker exhausted retries: #{exception.class}: #{exception.message}")
    GroupDirectory::Indexing.release_schedule!
    GroupDirectory::Indexing.recover!
  end

  def perform
    ids = []
    members = []
    acked = false
    return GroupDirectory::Indexing.release_schedule! unless GroupDirectory::Indexing.live_sync_enabled?

    GroupDirectory::Indexing.touch_schedule!
    GroupDirectory::Indexing.reclaim_expired!
    unless GroupDirectory::Indexing.index_ready?
      Rails.logger.warn('Group directory index is missing. Run tootctl search deploy --only group_directory before GROUP_DIRECTORY_INDEX=true. Pending ids were left in Redis.')
      GroupDirectory::Indexing.release_schedule!
      return
    end

    members = GroupDirectory::Indexing.claim_batch
    if members.empty?
      GroupDirectory::Indexing.release_if_idle!
      return
    end

    ids = members.map { |member| GroupDirectory::Indexing.account_id(member) }
    GroupDirectory::Import.call(ids)
    GroupDirectory::Indexing.ack(members)
    acked = true
    GroupDirectory::Indexing.continue!
  rescue StandardError => e
    begin
      GroupDirectory::Indexing.return_to_pending(members) unless acked
    rescue StandardError => return_error
      Rails.logger.error("Group directory index return failed: #{return_error.class}: #{return_error.message}")
    end
    GroupDirectory::Indexing.release_schedule!
    Rails.logger.error("Group directory index sync failed for #{Array(ids).size} accounts: #{e.class}: #{e.message}")
    raise
  end
end
