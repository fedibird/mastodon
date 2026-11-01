# frozen_string_literal: true

class Api::V1::GroupDirectoriesController < Api::BaseController
  before_action :set_accounts

  def show
    render json: @accounts, each_serializer: REST::GroupDirectoryAccountSerializer
  end

  private

  def set_accounts
    @accounts = GroupDirectory::Query.new(
      viewer: current_account,
      params: params,
      limit: limit_param(DEFAULT_ACCOUNTS_LIMIT)
    ).results
  end
end
