# frozen_string_literal: true

class Settings::ExternalServices::DeepLCredentialsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_recent_challenge!

  def create
    DeepLCredentialSettings.new(current_user).save!(params[:api_key])
    redirect_to settings_external_services_deepl_path, notice: I18n.t('external_credentials.saved'), status: :see_other
  rescue DeepLCredentialSettings::InvalidKey
    redirect_to settings_external_services_deepl_path, alert: I18n.t('external_credentials.invalid_key'), status: :see_other
  rescue DeepLCredentialSettings::Unavailable, UserCredentialVault::ConfigurationError
    redirect_to settings_external_services_deepl_path, alert: I18n.t('external_credentials.storage_unavailable'), status: :see_other
  rescue DeepLCredentialSettings::Ambiguous
    redirect_to settings_external_services_deepl_path, alert: I18n.t('external_credentials.ambiguous'), status: :see_other
  rescue DeepLCredentialSettings::SaveFailed
    redirect_to settings_external_services_deepl_path, alert: I18n.t('external_credentials.save_failed'), status: :see_other
  end

  def destroy
    DeepLCredentialSettings.new(current_user).delete!(params[:id])
    redirect_to settings_external_services_deepl_path, notice: I18n.t('external_credentials.deleted'), status: :see_other
  end

  private

  # A missing challenge redirects to the DeepL page. This action does not
  # render the challenge, so the submitted API key is not copied into that form.
  def require_recent_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    redirect_to settings_external_services_deepl_path, status: :see_other
  end
end
