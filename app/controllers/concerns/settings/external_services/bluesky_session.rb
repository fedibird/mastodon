# frozen_string_literal: true

module Settings::ExternalServices::BlueskySession
  extend ActiveSupport::Concern

  private

  def atproto_browser_token
    session[:atproto_oauth_browser] ||= SecureRandom.urlsafe_base64(32)
  end

  def atproto_alert(code)
    string = code.to_s
    if ExternalBridge::Atproto::Codes::CODES.include?(string)
      I18n.t("external_bridge.atproto.errors.#{string}")
    else
      I18n.t('external_bridge.atproto.errors.authorization_failed')
    end
  end
end
