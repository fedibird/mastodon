# frozen_string_literal: true

class Settings::ExternalServices::BlueskyCallbacksController < Settings::BaseController
  include Settings::ExternalServices::BlueskySession

  def show
    ExternalBridge::Atproto::Callback.call(
      user: current_user,
      browser_token: session[:atproto_oauth_browser].to_s,
      state: params[:state].to_s,
      iss: params[:iss].to_s,
      code: params[:code].to_s,
      provider_error: params[:error].to_s
    )
    redirect_to settings_external_services_bluesky_path, notice: I18n.t('external_bridge.atproto.connected'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_bluesky_path, alert: atproto_alert(e.code), status: :see_other
  end
end
