# frozen_string_literal: true

class Trends::TagFilter
  KEYS = %i(
    trending
    status
  ).freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  def results
    scope = if params[:status] == 'pending_review'
              Tag.unscoped
            else
              trending_scope
            end

    params.each do |key, value|
      next if key.to_s == 'page' || value.blank?
      next if key.to_s == 'status' && value.to_s == 'all'

      scope.merge!(scope_for(key, value.to_s.strip))
    end

    scope
  end

  private

  def scope_for(key, value)
    case key.to_s
    when 'status'
      status_scope(value)
    else
      raise "Unknown filter: #{key}"
    end
  end

  def trending_scope
    Trends.tags.query.to_arel
  end

  def status_scope(value)
    case value.to_s
    when 'approved'
      Tag.reviewed.merge(Tag.trendable)
    when 'rejected'
      reviewed_and_not_trendable
    when 'pending_review'
      Tag.pending_review
    else
      raise "Unknown status: #{value}"
    end
  end

  # Reviewed rows only. A nil trendable follows Setting.trendable_by_default,
  # matching Tag#trendable? and the review badge.
  def reviewed_and_not_trendable
    if Setting.trendable_by_default
      Tag.reviewed.merge(Tag.not_trendable)
    else
      Tag.reviewed.where(trendable: [false, nil])
    end
  end
end
