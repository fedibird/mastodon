# frozen_string_literal: true

class Api::V1::Accounts::CredentialsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }, except: [:update]
  before_action -> { doorkeeper_authorize! :write, :'write:accounts' }, only: [:update]
  before_action :require_user!

  def show
    @account = current_account.tap do |account|
      account.locked = false if account.user.setting_unlocked_for_official_app && (mastodon_for_ios? || mastodon_for_android?)
    end

    render json: @account, serializer: REST::CredentialAccountSerializer
  end

  def update
    @account = current_account
    UpdateAccountService.new.call(@account, account_params, raise_error: true)
    UserSettingsDecorator.new(current_user).update(user_settings_params) if user_settings_params
    ActivityPub::UpdateDistributionWorker.perform_async(@account.id)
    render json: @account, serializer: REST::CredentialAccountSerializer
  end

  private

  def account_params
    params.permit(
      :display_name,
      :note,
      :avatar,
      :header,
      :locked,
      :bot,
      :discoverable,
      :searchability,
      :birthday,
      :birth_year,
      :birth_month,
      :birth_day,
      :location,
      :indexable,
      :followed_message,
      fields_attributes: [:name, :value]
    )
  end

  def user_settings_params
    return nil if params[:source].blank?

    source_params = params.require(:source)

    {
      'setting_default_privacy' => source_params.fetch(:privacy, @account.user.setting_default_privacy),
      'setting_default_sensitive' => source_params.fetch(:sensitive, @account.user.setting_default_sensitive),
      'setting_default_language' => source_params.fetch(:language, @account.user.setting_default_language),
    }
  end
end
