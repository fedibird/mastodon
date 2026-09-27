# frozen_string_literal: true

module PreviewCardTrendReview
  extend ActiveSupport::Concern

  HOST_SQL = <<~SQL.squish
    CROSS JOIN LATERAL (
      SELECT lower(split_part(split_part(regexp_replace(preview_cards.url, '^https?://', ''), '/', 1), ':', 1)) AS host
    ) preview_card_hosts
  SQL

  MATCHED_PROVIDER_SQL = <<~SQL.squish
    LEFT JOIN LATERAL (
      SELECT preview_card_providers.id,
             preview_card_providers.domain,
             preview_card_providers.trendable,
             preview_card_providers.reviewed_at
      FROM preview_card_providers
      WHERE preview_card_providers.domain = preview_card_hosts.host
         OR preview_card_hosts.host LIKE '%.' || preview_card_providers.domain
      ORDER BY char_length(preview_card_providers.domain) DESC
      LIMIT 1
    ) matched_preview_card_providers ON TRUE
  SQL

  included do
    scope :with_matched_provider, -> { joins(HOST_SQL).joins(MATCHED_PROVIDER_SQL) }
    scope :review_pending, -> { with_matched_provider.where(klass.review_pending_sql) }
    scope :review_approved, -> { with_matched_provider.where(klass.review_approved_sql) }
    scope :review_rejected, -> { with_matched_provider.where(klass.review_rejected_sql) }
  end

  class_methods do
    def pending_trend_count
      review_pending.joins(:trend).count
    end

    def trend_candidate_counts_for(providers)
      ids = Array(providers).map(&:id)
      return {} if ids.empty?

      joins(:trend)
        .with_matched_provider
        .where('matched_preview_card_providers.id IN (?)', ids)
        .group('matched_preview_card_providers.id')
        .count
        .transform_keys(&:to_i)
    end

    def review_pending_sql
      <<~SQL.squish
        preview_cards.trendable IS NULL
        AND matched_preview_card_providers.reviewed_at IS NULL
      SQL
    end

    def review_approved_sql
      <<~SQL.squish
        preview_cards.trendable = TRUE
        OR (
          preview_cards.trendable IS NULL
          AND matched_preview_card_providers.reviewed_at IS NOT NULL
          AND matched_preview_card_providers.trendable IS TRUE
        )
      SQL
    end

    def review_rejected_sql
      <<~SQL.squish
        preview_cards.trendable = FALSE
        OR (
          preview_cards.trendable IS NULL
          AND matched_preview_card_providers.reviewed_at IS NOT NULL
          AND matched_preview_card_providers.trendable IS NOT TRUE
        )
      SQL
    end
  end
end
