# frozen_string_literal: true

class Settings::ExternalServices::RSSSubscriptionsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_recent_challenge!

  def create
    ExternalBridge::RSS::Subscribe.new.call(user: current_user, url: params[:feed_url])
    redirect_to settings_external_services_rss_path, notice: I18n.t('external_bridge.subscribed'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: failure_alert(e), status: :see_other
  end

  def pause
    ExternalBridge::RSS::Subscribe.new.pause!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: lookup_alert(e), status: :see_other
  end

  def resume
    ExternalBridge::RSS::Subscribe.new.resume!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: failure_alert(e), status: :see_other
  end

  # The removal is accepted here and finished by a background job. The page
  # shows its progress; this response does not claim it is done.
  def destroy
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: current_user, subscription_id: params[:id])
    redirect_to settings_external_services_rss_path, notice: I18n.t('external_bridge.unsubscribed'), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path, alert: lookup_alert(e), status: :see_other
  end

  def update
    subscription = ExternalBridge::RSS::PresentationUpdate.new.call(
      user: current_user,
      subscription_id: params[:id],
      media_sensitive: params[:media_sensitive],
      cw_enabled: params[:cw_enabled]
    )
    redirect_to settings_external_services_rss_path(page_options), notice: presentation_notice(subscription), status: :see_other
  rescue ExternalBridge::Error => e
    redirect_to settings_external_services_rss_path(page_options), alert: presentation_alert(e), status: :see_other
  end

  private

  def lookup_alert(error)
    return I18n.t('external_bridge.errors.subscription_deleting') if error.code == 'subscription_deleting'

    I18n.t('external_bridge.errors.not_found')
  end

  def failure_alert(error)
    ExternalBridge::RSS::ErrorMessage.for(error.code)
  end

  def presentation_notice(subscription)
    if subscription.presentation_revision.to_i > subscription.presentation_applied_revision.to_i
      I18n.t('external_bridge.presentation.saved_applying')
    else
      I18n.t('external_bridge.presentation.saved')
    end
  end

  def presentation_alert(error)
    return I18n.t('external_bridge.errors.subscription_deleting') if error.code == 'subscription_deleting'
    return I18n.t('external_bridge.errors.invalid_presentation') if error.code == 'invalid_presentation'

    I18n.t('external_bridge.errors.not_found')
  end

  def page_number
    text = params[:page].to_s
    return nil unless text.match?(/\A\d+\z/)

    text.to_i
  end

  def page_options
    number = page_number
    number.present? && number > 1 ? { page: number } : {}
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
