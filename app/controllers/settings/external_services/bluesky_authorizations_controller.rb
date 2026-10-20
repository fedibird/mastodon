# frozen_string_literal: true

class Settings::ExternalServices::BlueskyAuthorizationsController < Settings::BaseController
  include ChallengableConcern
  include Settings::ExternalServices::BlueskySession

  before_action :require_recent_challenge!

  def create
    url = ExternalBridge::Atproto::Authorize.call(
      user: current_user,
      identifier: params[:account].to_s,
      browser_token: atproto_browser_token
    )
    redirect_to verified_authorization_url(url)
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_bluesky_path, alert: atproto_alert(e.code), status: :see_other
  end

  private

  def verified_authorization_url(url)
    uri = Addressable::URI.parse(url)
    raise ExternalBridge::Error, :authorization_failed unless uri&.scheme == 'https' && uri.user.nil?

    url
  rescue Addressable::URI::InvalidURIError
    raise ExternalBridge::Error, :authorization_failed
  end

  def require_recent_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    redirect_to settings_external_services_bluesky_path, status: :see_other
  end
end
