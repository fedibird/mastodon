# frozen_string_literal: true

class Settings::ExternalServices::BlueskyIdentitiesController < Settings::BaseController
  include ChallengableConcern
  include Settings::ExternalServices::BlueskySession

  before_action :require_recent_challenge!

  def destroy
    ExternalBridge::Atproto::Disconnect.call(user: current_user, identity_id: params[:id])
    redirect_to settings_external_services_bluesky_path, notice: I18n.t('external_bridge.atproto.disconnected'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_bluesky_path, alert: atproto_alert(e.code), status: :see_other
  end

  def check
    ExternalBridge::Atproto::Refresh.call(user: current_user, identity_id: params[:id])
    redirect_to settings_external_services_bluesky_path, notice: I18n.t('external_bridge.atproto.checked'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_bluesky_path, alert: atproto_alert(e.code), status: :see_other
  end

  private

  def require_recent_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    redirect_to settings_external_services_bluesky_path, status: :see_other
  end
end
