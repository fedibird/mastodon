# frozen_string_literal: true

class TrendingTags
  KEY                  = 'trending_tags'
  EXPIRE_HISTORY_AFTER = 7.days.seconds
  EXPIRE_TRENDS_AFTER  = 1.day.seconds
  THRESHOLD            = 5
  LIMIT                = 10
  REVIEW_THRESHOLD     = 3

  class << self
    include Redisable

    def record_use!(tag, account, status: nil, at_time: Time.now.utc)
      tag.use!(account, status: status, at_time: at_time)
    end

    def update!(at_time = Time.now.utc)
      Trends.tags.refresh(at_time)
      notify_unreviewed!
    end

    def notify_unreviewed!
      tag_ids = redis.zrevrange("#{KEY}:allowed", 0, -1)
      tags = Tag.where(id: tag_ids)
      users_for_review = User.those_who_can(:manage_taxonomies).includes(:account).to_a.select { |user| user.functional? && user.allows_trending_tag_emails? }

      tags.each do |tag|
        current_rank = redis.zrevrank("#{KEY}:allowed", tag.id)
        next unless !tag.trendable? && current_rank.present? && current_rank <= REVIEW_THRESHOLD && tag.requires_review_notification?

        tag.touch(:requested_review_at)
        users_for_review.each do |user|
          AdminMailer.new_trending_tag(user.account, tag).deliver_later!
        end
      end
    end

    def get(limit, filtered: true)
      scope = Trends.tags.query
      scope = scope.allowed if filtered
      scope.limit(limit).to_a
    end

    def trending?(tag)
      rank = Trends.tags.rank(tag.id)
      rank.present? && rank < LIMIT * 2
    end
  end
end
