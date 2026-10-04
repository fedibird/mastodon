# frozen_string_literal: true

class RefreshEmojiReactionCacheWorker
  include Sidekiq::Worker

  # :until_executing keeps one queued job per status, then releases the lock
  # when perform starts. A newer invalidation can enqueue the following rebuild
  # instead of being dropped while this one is still running.
  sidekiq_options queue: 'pull', retry: 1, dead: false, lock: :until_executing

  # Positional so Sidekiq can enqueue `perform_async(status_id, true)`.
  def perform(status_id, force = false) # rubocop:disable Style/OptionalBooleanParameter
    status = Status.unscoped.find(status_id)

    if force
      status.refresh_grouped_emoji_reactions!(force: true)
    else
      status.refresh_grouped_emoji_reactions_if_dirty!
    end
  rescue ActiveRecord::RecordNotFound
    StatusStat.where(status_id: status_id).update_all(emoji_reactions_cache_dirty: false)
    true
  end
end
