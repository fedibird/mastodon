# frozen_string_literal: true

module Admin::TrendReviewHelper
  def trend_review_badge(record)
    label, tone = trend_review_decision(record)
    tag.span(label, class: "information-badge trend-review-badge trend-review-badge--#{tone}")
  end

  def trend_candidate_stats(rank: nil, score: nil)
    parts = []
    parts << tag.span(t('admin.trends.review.candidate_rank', rank: rank)) if rank.present? && rank.to_i.positive?
    parts << tag.span(t('admin.trends.review.candidate_score', score: number_with_precision(score.to_f, precision: 2))) unless score.nil?
    safe_join(parts)
  end

  private

  def trend_review_decision(record)
    case record
    when Status
      inherited_decision(record.attributes['trendable'], record.account, :account)
    when PreviewCard
      preview_card_decision(record)
    else
      simple_trend_review_decision(record)
    end
  end

  def preview_card_decision(card)
    own = card.attributes['trendable']
    return individual_decision(own) unless own.nil?

    provider = card.provider
    label, tone = inherited_decision(nil, provider, :provider)
    label = t('admin.trends.review.decision.with_source', decision: label, source: provider.domain) if provider
    [label, tone]
  end

  def inherited_decision(own_trendable, parent, source)
    return individual_decision(own_trendable) unless own_trendable.nil?

    if parent.nil? || parent.requires_review?
      [t("admin.trends.review.decision.#{source}_pending"), 'pending']
    elsif parent.trendable?
      [t("admin.trends.review.decision.#{source}_approved"), 'approved']
    else
      [t("admin.trends.review.decision.#{source}_rejected"), 'rejected']
    end
  end

  def individual_decision(value)
    if value
      [t('admin.trends.review.decision.individual_approved'), 'approved']
    else
      [t('admin.trends.review.decision.individual_rejected'), 'rejected']
    end
  end

  def simple_trend_review_decision(record)
    if record.requires_review?
      [t('admin.trends.review.decision.pending'), 'pending']
    elsif record.trendable?
      [t('admin.trends.review.decision.approved'), 'approved']
    else
      [t('admin.trends.review.decision.rejected'), 'rejected']
    end
  end
end
