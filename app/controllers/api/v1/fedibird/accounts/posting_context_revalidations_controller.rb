# frozen_string_literal: true

class Api::V1::Fedibird::Accounts::PostingContextRevalidationsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }, only: :show
  before_action -> { doorkeeper_authorize! :write }, only: :create
  before_action :require_user!
  before_action :require_administrator!
  before_action :set_account

  def show
    render json: registry.read(@account)
  end

  def create
    unless PostingContext::RevalidationEligibility.eligible?(@account)
      render json: { error: 'This account cannot be revalidated' }, status: 422
      return
    end

    outcome = registry.request!(@account, requester: current_user)
    if outcome.status == :created
      PostingContext::RevalidateGroupEvidenceWorker.perform_async(@account.id, outcome.payload[:request_id])
    end

    if outcome.retry_after
      response.headers['Retry-After'] = outcome.retry_after.to_s
      render json: { error: outcome.status.to_s }, status: 429
      return
    end

    render json: outcome.payload, status: 202
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end

  def require_administrator!
    return if current_user&.can?(:administrator)

    render json: { error: 'This action is not allowed' }, status: 403
  end

  def registry
    PostingContext::RevalidationRegistry.new
  end
end
