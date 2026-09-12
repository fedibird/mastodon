# frozen_string_literal: true

module Admin
  # Read-only Analysis UI over the moderation ledger: renders the behavioural
  # metrics computed by Moderation::BehavioralMetricsService for one subject.
  # It only visualizes observed counts/rates — no scoring, thresholds,
  # recommendations, or enforcement, and it never mutates the ledger.
  class ModerationMetricsController < BaseController
    before_action :set_subject

    def show
      authorize :moderation_metric, :show?

      @metrics = Moderation::BehavioralMetricsService.new.call(@subject)
    end

    private

    # :id is the ModerationSubject id. A stale/invalid id fails closed with 404
    # (via rescue_from ActiveRecord::RecordNotFound).
    def set_subject
      @subject = ModerationSubject.find(params[:id])
    end
  end
end
