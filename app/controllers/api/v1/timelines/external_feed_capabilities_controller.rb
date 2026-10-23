# frozen_string_literal: true

class Api::V1::Timelines::ExternalFeedCapabilitiesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action :require_user!

  # Display permission for the authenticated user. Not an authorization
  # substitute, and not inferred from Account#user. The boot value is stale
  # after the flag or the tester list changes.
  def show
    render json: { permitted: ExternalBridge::Feeds::Feature.permitted?(current_user) }
  end
end
