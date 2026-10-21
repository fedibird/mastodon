# frozen_string_literal: true

class Settings::ExternalServices::RSSSubscriptionsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_recent_challenge!

  def create
    ExternalBridge::RSS::Subscribe.new.call(user: current_user, url: params[:url])
    redirect_to settings_external_services_rss_path, notice: I18n.t('external_bridge.subscribed'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: failure_alert(e), status: :see_other
  end

  def pause
    ExternalBridge::RSS::Subscribe.new.pause!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, status: :see_other
  rescue ExternalBridge::Error
    redirect_to settings_external_services_rss_path, alert: I18n.t('external_bridge.errors.not_found'), status: :see_other
  end

  def resume
    ExternalBridge::RSS::Subscribe.new.resume!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: failure_alert(e), status: :see_other
  end

  def destroy
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, notice: I18n.t('external_bridge.unsubscribed'), status: :see_other
  rescue ExternalBridge::Error
    redirect_to settings_external_services_rss_path, alert: I18n.t('external_bridge.errors.not_found'), status: :see_other
  end

  private

  def failure_alert(error)
    I18n.t("external_bridge.errors.#{error.code}", default: I18n.t('external_bridge.errors.fetch_failed'))
  end

  def require_recent_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    redirect_to settings_external_services_rss_path, status: :see_other
  end
end
