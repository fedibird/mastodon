# frozen_string_literal: true

class Api::V1::AccountSubscribesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:follows' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :write, :'write:follows' }, except: [:index, :show]

  before_action :require_user!
  before_action :set_account_subscribe, except: [:index, :create]

  def index
    @account_subscribes = AccountSubscribe.where(account: current_account).all
    render json: @account_subscribes, each_serializer: REST::AccountSubscribeSerializer
  end

  def show
    render json: @account_subscribe, serializer: REST::AccountSubscribeSerializer
  end

  def create
    @account_subscribe = AccountSubscribe.create!(account_subscribe_params.merge(account: current_account))
    render json: @account_subscribe, serializer: REST::AccountSubscribeSerializer
  end

  def update
    @account_subscribe.update!(account_subscribe_params)
    render json: @account_subscribe, serializer: REST::AccountSubscribeSerializer
  end

  def destroy
    @account_subscribe.destroy!
    render_empty
  end

  private

  def set_account_subscribe
    @account_subscribe = AccountSubscribe.where(account: current_account).find(params[:id])
  end

  def account_subscribe_params
    params.permit(:acct)
  end
end
