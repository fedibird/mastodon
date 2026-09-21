# frozen_string_literal: true

module Admin
  class ActionReviewsController < BaseController
    before_action :set_action_review_request, only: [:show]

    def index
      authorize :action_review_request, :index?

      @action_review_requests = filtered_requests.includes(:actor_account, :reviewer_account).page(params[:page])
    end

    def show
      authorize @action_review_request, :show?
    end

    private

    def filtered_requests
      ActionReviewRequestFilter.new(filter_params).results
    end

    def filter_params
      params.slice(*ActionReviewRequestFilter::KEYS).permit(*ActionReviewRequestFilter::KEYS)
    end

    def set_action_review_request
      @action_review_request = ActionReviewRequest.find(params[:id])
    end
  end
end
