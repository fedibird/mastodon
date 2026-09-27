# frozen_string_literal: true

module StatusTrendReview
  extend ActiveSupport::Concern

  included do
    scope :review_pending, -> { joins(:account).where(statuses: { trendable: nil }, accounts: { reviewed_at: nil }) }
    scope :review_approved, -> { joins(:account).where(klass.review_approved_sql) }
    scope :review_rejected, -> { joins(:account).where(klass.review_rejected_sql) }
  end

  class_methods do
    def pending_trend_count
      review_pending.joins(:trend).count
    end

    def review_approved_sql
      <<~SQL.squish
        statuses.trendable = TRUE
        OR (
          statuses.trendable IS NULL
          AND accounts.reviewed_at IS NOT NULL
          AND #{account_trendable_sql(true)}
        )
      SQL
    end

    def review_rejected_sql
      <<~SQL.squish
        statuses.trendable = FALSE
        OR (
          statuses.trendable IS NULL
          AND accounts.reviewed_at IS NOT NULL
          AND #{account_trendable_sql(false)}
        )
      SQL
    end

    def account_trendable_sql(approved)
      if Setting.trendable_by_default
        approved ? '(accounts.trendable = TRUE OR accounts.trendable IS NULL)' : 'accounts.trendable = FALSE'
      else
        approved ? 'accounts.trendable = TRUE' : '(accounts.trendable = FALSE OR accounts.trendable IS NULL)'
      end
    end
  end
end
