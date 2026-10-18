# frozen_string_literal: true

class Api::V1::Statuses::ReblogWrappersController < Api::BaseController
  include Authorization

  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :set_status

  def show
    result = AccountContext::ReblogWrapperLookup.call(
      viewer: current_account,
      original: @status,
      account_id: params[:account_id]
    )

    render json: {
      state: result.state,
      reason: result.reason,
      id: result.status_id&.to_s,
      account_id: result.account_id&.to_s,
    }
  end

  private

  def set_status
    @status = Status.include_expired.find(params[:status_id])
    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    # Same response as a missing row. A 403 would confirm that the status exists.
    render json: { error: 'Record not found' }, status: 404
  end
end
