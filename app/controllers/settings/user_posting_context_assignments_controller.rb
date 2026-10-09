# frozen_string_literal: true

class Settings::UserPostingContextAssignmentsController < Settings::BaseController
  PER_PAGE = 20

  before_action :require_posting_style_access!

  def index
    prepare_index
  end

  def release
    change_assignment(:release!, 'user_posting_context_assignments.released')
  end

  def decline
    change_assignment(:decline!, 'user_posting_context_assignments.declined')
  end

  private

  def require_posting_style_access!
    forbidden unless current_user&.functional? && current_user&.can?(:administrator)
  end

  def change_assignment(operation, notice_key)
    assignment = current_user.user_posting_context_assignments.find(params[:id])
    if operation == :release!
      assignment.release!(params[:lock_version])
    else
      assignment.decline!(params[:lock_version])
    end
    redirect_to assignments_path, notice: I18n.t(notice_key)
  rescue ActiveRecord::StaleObjectError
    prepare_index
    flash.now[:alert] = I18n.t('user_posting_context_assignments.stale')
    render :index, status: :conflict
  end

  def prepare_index
    @filter_style = filter_style
    scope = current_user.user_posting_context_assignments.includes(:user_posting_context).order(:surface_kind, :surface_key, :id)
    scope = scope.where(user_posting_context_id: @filter_style.id) if @filter_style
    @assignments = scope.page(params[:page]).per(PER_PAGE)
    @places = UserPostingContextAssignment::PlaceCatalog.for(current_user, @assignments)
  end

  def filter_style
    return if params[:user_posting_context_id].blank?

    current_user.user_posting_contexts.find(params[:user_posting_context_id])
  end

  def assignments_path
    settings_user_posting_context_assignments_path(list_params)
  end

  def list_params
    {
      user_posting_context_id: params[:user_posting_context_id].presence,
      page: params[:page].presence,
    }.compact
  end
end
