# frozen_string_literal: true

class GroupDirectoryIndexWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 5

  def perform
    ids = nil
    return GroupDirectory::Indexing.release_schedule! unless GroupDirectory::Indexing.live_sync_enabled?

    unless GroupDirectory::Indexing.index_ready?
      Rails.logger.warn('Group directory index is missing. Run tootctl search deploy --only group_directory before GROUP_DIRECTORY_INDEX=true. Pending ids were left in Redis.')
      GroupDirectory::Indexing.release_schedule!
      return
    end

    ids = GroupDirectory::Indexing.pop_batch.map(&:to_i)
    if ids.empty?
      GroupDirectory::Indexing.release_if_idle!
      return
    end

    GroupDirectoryIndex.import!(ids)
    GroupDirectory::Indexing.continue!
  rescue StandardError => e
    GroupDirectory::Indexing.requeue(ids)
    Rails.logger.error("Group directory index sync failed for #{Array(ids).size} accounts: #{e.class}: #{e.message}")
    raise
  end
end
