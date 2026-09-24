# frozen_string_literal: true

class Api::V1::Statuses::HistoriesController < Api::BaseController
  include Authorization

  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :set_status

  def show
    cache_if_unauthenticated!
    render json: status_edits, each_serializer: REST::StatusEditSerializer
  end

  private

  def status_edits
    @status.edits.includes(:account, status: [:account]).to_a.presence || [@status.build_snapshot(at_time: @status.edited_at || @status.created_at)]
  end

  def set_status
    @status = Status.include_expired.find(params[:status_id])
    # RecordNotFound renders 404. authorize's NotPermittedError is rescued
    # by the API base controller as 403, which would reveal a private status.
    raise ActiveRecord::RecordNotFound unless StatusPolicy.new(current_account, @status).show?
  end
end
