# frozen_string_literal: true

class Api::V1::Fedibird::Accounts::PostingContextsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }
  before_action :require_user!
  before_action :set_account

  def show
    render json: PostingContext::DiscoveryService.new.call(@account, viewer: current_user.account)
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end
end
