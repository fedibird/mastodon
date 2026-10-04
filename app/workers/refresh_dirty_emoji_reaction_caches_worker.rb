# frozen_string_literal: true

# Drains status_stats rows explicitly marked emoji_reactions_cache_dirty.
# This is not a periodic self-heal. Callers enqueue it after an invalidation.
class RefreshDirtyEmojiReactionCachesWorker
  include Sidekiq::Worker

  # Hundreds of synchronous rebuilds per job. A follow-up job continues the
  # scan so a large custom-emoji invalidation is not one endless perform.
  BATCH_SIZE = 500

  # :until_executing dedupes queued jobs but releases the lock when perform
  # starts, so a dirty mark that arrives during this batch can enqueue the
  # next pass instead of being discarded as a duplicate.
  sidekiq_options queue: 'pull', retry: 1, dead: false, lock: :until_executing

  def perform(after_status_id = nil)
    after_status_id = after_status_id.to_i
    status_ids = dirty_status_ids_after(after_status_id)

    if status_ids.empty?
      self.class.perform_async if after_status_id.positive? && dirty_exists?
      return
    end

    failed_ids = []

    status_ids.each do |status_id|
      failed_ids << status_id unless refresh_status(status_id)
    end

    if dirty_exists_after?(status_ids.last)
      self.class.perform_async(status_ids.last)
    elsif dirty_exists_outside?(failed_ids)
      self.class.perform_async
    end
  end

  private

  def dirty_status_ids_after(after_status_id)
    scope = StatusStat.where(emoji_reactions_cache_dirty: true).order(:status_id).limit(BATCH_SIZE)
    scope = scope.where(StatusStat.arel_table[:status_id].gt(after_status_id)) if after_status_id.positive?
    scope.pluck(:status_id)
  end

  def refresh_status(status_id)
    Status.unscoped.find(status_id).refresh_grouped_emoji_reactions_if_dirty!
    true
  rescue ActiveRecord::RecordNotFound
    StatusStat.where(status_id: status_id).update_all(emoji_reactions_cache_dirty: false)
    true
  rescue StandardError => e
    Rails.logger.error("Failed to refresh emoji reaction cache for status #{status_id}: #{e.class}: #{e.message}")
    # Hand the dirty row to the per-status worker. Its retry: 1 covers a
    # transient failure without scanning this poison id from the batch worker
    # again on the next tick.
    RefreshEmojiReactionCacheWorker.perform_async(status_id)
    false
  end

  def dirty_exists?
    StatusStat.where(emoji_reactions_cache_dirty: true).exists?
  end

  def dirty_exists_after?(status_id)
    StatusStat.where(emoji_reactions_cache_dirty: true).where(StatusStat.arel_table[:status_id].gt(status_id)).exists?
  end

  def dirty_exists_outside?(failed_ids)
    scope = StatusStat.where(emoji_reactions_cache_dirty: true)
    scope = scope.where.not(status_id: failed_ids) if failed_ids.present?
    scope.exists?
  end
end
