# frozen_string_literal: true

module TrendsReviewQueue
  extend ActiveSupport::Concern

  private

  def ensure_default_review_status!
    return false if params[:status].present?

    redirect_to url_for(filter_params.to_h.symbolize_keys.merge(action: :index, status: 'pending_review'))
    true
  end
end
