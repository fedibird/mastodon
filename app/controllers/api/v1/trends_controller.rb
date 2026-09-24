# frozen_string_literal: true

class Api::V1::TrendsController < Api::V1::Trends::TagsController
  private

  def next_path
    api_v1_trends_url pagination_params(offset: offset_param + limit_param(DEFAULT_TAGS_LIMIT)) if records_continue?
  end

  def prev_path
    api_v1_trends_url pagination_params(offset: offset_param - limit_param(DEFAULT_TAGS_LIMIT)) if offset_param > limit_param(DEFAULT_TAGS_LIMIT)
  end
end
