# frozen_string_literal: true

class Trends::PreviewCardFilter
  KEYS = %i(
    trending
    locale
    status
  ).freeze

  IGNORED_PARAMS = %w(page).freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  def results
    scope = initial_scope

    params.each do |key, value|
      next if IGNORED_PARAMS.include?(key.to_s) || value.blank?

      filtered = scope_for(key, value.to_s.strip)
      scope.merge!(filtered) if filtered
    end

    scope
  end

  private

  def initial_scope
    PreviewCard.select(PreviewCard.arel_table[Arel.star])
               .joins(:trend)
               .eager_load(:trend)
               .reorder(score: :desc)
  end

  def scope_for(key, value)
    case key.to_s
    when 'trending'
      trending_scope(value)
    when 'locale'
      PreviewCardTrend.where(language: value)
    when 'status'
      review_scope(value)
    else
      raise Mastodon::InvalidParameterError, "Unknown filter: #{key}"
    end
  end

  def review_scope(value)
    case value
    when 'pending_review'
      PreviewCard.review_pending
    when 'approved'
      PreviewCard.review_approved
    when 'rejected'
      PreviewCard.review_rejected
    when 'all'
      nil
    else
      raise Mastodon::InvalidParameterError, "Unknown status: #{value}"
    end
  end

  def trending_scope(value)
    case value
    when 'allowed'
      PreviewCardTrend.allowed
    else
      PreviewCardTrend.all
    end
  end
end
