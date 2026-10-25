# frozen_string_literal: true

namespace :emoji_reactions do
  namespace :shadow do
    desc 'Summarize emoji reaction resolver shadow counters (HOURS=24)'
    task report: :environment do
      hours = [ENV.fetch('HOURS', '24').to_i, 1].max
      fields = EmojiReactionCapability::ShadowReport.collect(hours: hours)
      puts EmojiReactionCapability::ShadowReport.render(EmojiReactionCapability::ShadowReport.summarize(fields))
    end

    desc 'Delete all shadow counters (rollback cleanup; counters also expire after 8 days)'
    task reset: :environment do
      pattern = "#{EmojiReactionCapability::ShadowRecorder::KEY_PREFIX}:*"
      deleted = 0
      RedisConfiguration.with do |conn|
        conn.scan_each(match: pattern) { |key| deleted += conn.del(key) }
      end
      puts "deleted #{deleted} bucket(s)"
    end
  end
end
