# frozen_string_literal: true

# Progress of the signed-in user's asynchronous RSS unsubscribes. Another user,
# including one who shares the account, gets 404 for an id that exists.
class Api::V1::ExternalBridge::RSS::SubscriptionDeletionsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, only: :retry
  before_action :require_user!

  def index
    rows = ExternalSubscriptionDeletion.where(user_id: current_user.id).order(id: :desc).limit(limit_param(20))
    render json: rows.map { |row| ExternalBridge::RSS::SubscriptionDeletionPayload.call(row) }
  end

  def show
    render json: ExternalBridge::RSS::SubscriptionDeletionPayload.call(deletion)
  end

  # Only a failed job moves. Any other state is returned as it is.
  def retry
    result = ExternalBridge::RSS::SubscriptionDeletionRetry.new.call(user: current_user, deletion_id: params[:id])
    render json: ExternalBridge::RSS::SubscriptionDeletionPayload.call(result), status: result.queued? ? 202 : 200
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  private

  def deletion
    ExternalSubscriptionDeletion.find_by!(id: params[:id], user_id: current_user.id)
  end
end
