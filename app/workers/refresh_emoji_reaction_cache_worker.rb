# frozen_string_literal: true

class RefreshEmojiReactionCacheWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 1, dead: false, lock: :until_executed

  def perform(status_id)
    Status.find(status_id).refresh_grouped_emoji_reactions!
  rescue ActiveRecord::RecordNotFound
    true
  end
end
