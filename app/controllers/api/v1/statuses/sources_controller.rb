# frozen_string_literal: true

class Api::V1::Statuses::SourcesController < Api::BaseController
  include Authorization

  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action :set_status

  def show
    render json: @status, serializer: REST::StatusSourceSerializer
  end

  private

  def set_status
    @status = Status.find(params[:status_id])
    raise ActiveRecord::RecordNotFound if ExternalBridge::ProjectionPrivacy.hidden_from?(@status, current_user&.id)

    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    not_found
  end
end
