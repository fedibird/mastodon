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
