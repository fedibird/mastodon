# frozen_string_literal: true

module Admin
  class ActionReviewsController < BaseController
    before_action :set_action_review_request, only: [:show, :approve, :reject]

    def index
      authorize :action_review_request, :index?

      @action_review_requests = filtered_requests.includes(:actor_account, :reviewer_account).page(params[:page])
    end

    def show
      authorize @action_review_request, :show?
      @account_migration_current_metrics = current_migration_metrics
    end

    def approve
      decide!('approve')
    end

    def reject
      decide!('reject')
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

    def decide!(verb)
      authorize @action_review_request, "#{verb}?"
      ActionReview::DecisionService.new.call(
        request: @action_review_request,
        decision: verb,
        reviewer_account: current_account,
        decision_note: params[:decision_note]
      )
      redirect_to admin_action_review_path(@action_review_request), notice: decision_notice(verb)
    rescue ActionReview::DecisionError, ActionReview::AdapterRegistry::UnknownAdapter, ActionReview::OperationRegistry::UnknownOperation
      redirect_to admin_action_review_path(@action_review_request), alert: I18n.t('admin.action_reviews.decision_failed')
    end

    def decision_notice(verb)
      if @action_review_request.operation_type == 'invite_creation'
        key = verb == 'approve' ? 'invite_approved_msg' : 'invite_stopped_msg'
        return I18n.t("admin.action_reviews.#{key}")
      end

      if @action_review_request.operation_type == 'account_migration'
        key = verb == 'approve' ? 'migration_approved_msg' : 'migration_stopped_msg'
        return I18n.t("admin.action_reviews.#{key}")
      end

      key = verb == 'approve' ? 'approved_msg' : 'stopped_msg'
      I18n.t("admin.action_reviews.#{key}")
    end

    # Fresh read for a pending migration only. Not written back onto the request.
    def current_migration_metrics
      request = @action_review_request
      return unless request.operation_type == 'account_migration' && request.pending_state?

      migration = request.resource
      return unless migration.is_a?(AccountMigration) && migration.account.present?

      AccountMigration::ReviewMetricsService.new.call(migration.account, as_of: Time.now.utc)
    end
  end
end
