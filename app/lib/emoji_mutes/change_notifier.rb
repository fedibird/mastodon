# frozen_string_literal: true

# Tells the signed-in user's stream that the collection revision moved.
# The payload is only the revision, never a mute definition or token.
class EmojiMutes::ChangeNotifier
  include Redisable

  def publish(account, revision)
    return if account.nil? || revision.nil?

    redis.publish("timeline:#{account.id}", Oj.dump(event: 'emoji_mutes_changed', payload: { revision: revision }))
  rescue Redis::BaseError => e
    Rails.logger.warn("emoji mute revision notify failed: #{e.class}")
  end
end
