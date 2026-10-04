# frozen_string_literal: true

class RefreshEmojiReactionCacheWorker
  include Sidekiq::Worker

  # :until_executing keeps one queued job per status, then releases the lock
  # when perform starts. A newer invalidation can enqueue the following rebuild
  # instead of being dropped while this one is still running.
  sidekiq_options queue: 'pull', retry: 1, dead: false, lock: :until_executing

  def perform(status_id)
    Status.unscoped.find(status_id).refresh_grouped_emoji_reactions_if_dirty!
  rescue ActiveRecord::RecordNotFound
    StatusStat.where(status_id: status_id).update_all(emoji_reactions_cache_dirty: false)
    true
  end
end
