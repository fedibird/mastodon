# frozen_string_literal: true
class Settings::AccountSubscribesController < Settings::BaseController
  layout 'admin'

  before_action :authenticate_user!
  before_action :set_account_subscribings, only: :index

  class AccountInput
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :acct, :string
  end

  def index
    @account_input = AccountInput.new
  end

  def create
    acct = account_subscribe_params[:acct].strip
    acct = acct[1..-1] if acct.start_with?("@")

    begin
      target_account = AccountSubscribeService.new.call(current_account, acct)
    rescue
      target_account = nil
    end

    if target_account
      redirect_to settings_account_subscribes_path
    else
      set_account_subscribings

      render :index
    end
  end

  def destroy
    target_account = current_account.active_subscribes.find(params[:id]).target_account
    UnsubscribeAccountService.new.call(current_account, target_account)
    redirect_to settings_account_subscribes_path
  end

  private

  def set_account_subscribings
    @account_subscribings = current_account.active_subscribes.order(:updated_at).reject(&:new_record?).map do |subscribing|
      {id: subscribing.id, acct: subscribing.target_account.acct}
    end
  end

  def account_subscribe_params
    params.require(:account_input).permit(:acct)
  end
end
