# frozen_string_literal: true

class PostProcessEmojiReactionCacheWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 1, dead: false

  def perform(custom_emoji_ids)
    EmojiReactionCacheInvalidator.mark_for_custom_emoji_ids(custom_emoji_ids)
    RefreshDirtyEmojiReactionCachesWorker.perform_async
  end
end
