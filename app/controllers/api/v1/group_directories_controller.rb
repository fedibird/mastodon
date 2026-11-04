# frozen_string_literal: true

class Api::V1::GroupDirectoriesController < Api::BaseController
  before_action :set_accounts

  rescue_from GroupDirectory::SearchUnavailable do |error|
    Rails.logger.error("Group directory search unavailable: #{error.reason}")
    ActiveSupport::Notifications.instrument('group_directory.search_unavailable', reason: error.reason)
    render json: { error: 'Group directory search is temporarily unavailable' }, status: 503
  end

  def show
    render json: @accounts, each_serializer: REST::GroupDirectoryAccountSerializer
  end

  private

  def set_accounts
    @accounts = GroupDirectory::Listing.new(
      viewer: current_account,
      params: params,
      limit: limit_param(DEFAULT_ACCOUNTS_LIMIT)
    ).results
  end
end
