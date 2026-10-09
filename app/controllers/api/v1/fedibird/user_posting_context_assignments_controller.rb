# frozen_string_literal: true

class Api::V1::Fedibird::UserPostingContextAssignmentsController < Api::BaseController
  rescue_from UserPostingContextAssignment::InvalidAssignment do |error|
    render json: { error: error.message }, status: 422
  end

  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }, only: :show
  before_action -> { doorkeeper_authorize! :write, :'write:accounts' }, only: [:update, :destroy]
  before_action :require_user!
  before_action :require_owner!

  def show
    kind, key = UserPostingContextAssignment.canonicalize!(current_user, params[:surface_kind], params[:surface_key])
    assignment = current_user.user_posting_context_assignments.find_by(surface_kind: kind, surface_key: key)
    render json: assignment ? assignment.api_payload : UserPostingContextAssignment.unset_payload(kind, key)
  end

  def update
    assignment = UserPostingContextAssignment.assign!(
      user: current_user,
      surface_kind: params[:surface_kind],
      surface_key: params[:surface_key],
      style: requested_style
    )
    render json: assignment.api_payload
  end

  def destroy
    kind, key = UserPostingContextAssignment.canonicalize!(current_user, params[:surface_kind], params[:surface_key])
    current_user.user_posting_context_assignments.find_by(surface_kind: kind, surface_key: key)&.destroy!
    render json: UserPostingContextAssignment.unset_payload(kind, key)
  end

  private

  def require_owner!
    raise Mastodon::NotPermittedError unless current_user.can?(:administrator)
  end

  def requested_style
    raise ActionController::ParameterMissing, :style_id unless params.key?(:style_id)
    return nil if params[:style_id].nil?

    style = current_user.user_posting_contexts.find_by(id: params[:style_id])
    return style if style

    record = UserPostingContextAssignment.new
    record.errors.add(:base, I18n.t('user_posting_context_assignments.errors.style'))
    raise UserPostingContextAssignment::InvalidAssignment, record
  end
end
