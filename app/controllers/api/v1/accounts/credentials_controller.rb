# frozen_string_literal: true

class Api::V1::Accounts::CredentialsController < Api::BaseController
  SOURCE_PREFERENCE_KEYS = {
    'default_privacy' => 'source.privacy',
    'default_language' => 'source.language',
    'default_sensitive' => 'source.sensitive',
  }.freeze

  before_action -> { doorkeeper_authorize! :profile, :read, :'read:accounts' }, except: [:update]
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

    source_settings = user_settings_params
    if source_settings
      UserSettingsDecorator.new(
        current_user,
        legacy_writer: UserPreferences::LegacyWriter.new(current_user)
      ).update(source_settings)
    end

    ActivityPub::UpdateDistributionWorker.perform_async(@account.id)
    render json: @account, serializer: REST::CredentialAccountSerializer
  rescue UserPreferences::InvalidInput => e
    render json: invalid_source_preferences(e), status: :unprocessable_entity
  end

  private

  def invalid_source_preferences(error)
    {
      error: 'Invalid source preferences',
      errors: error.errors.map { |item| source_preference_error(item) },
    }
  end

  def source_preference_error(item)
    {
      key: SOURCE_PREFERENCE_KEYS.fetch(item['key']),
      code: item['code'],
    }
  end

  def account_params
    params.permit(
      :display_name,
      :note,
      :avatar,
      :header,
      :locked,
      :bot,
      :discoverable,
      :hide_collections,
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
