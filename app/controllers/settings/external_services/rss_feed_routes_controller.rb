# frozen_string_literal: true

class Settings::ExternalServices::RSSFeedRoutesController < Settings::BaseController
  include ChallengableConcern

  before_action :require_recent_challenge!

  def update
    ExternalBridge::FeedRoutes::Update.new.call(
      user: current_user,
      subscription_id: params[:id],
      home: route_value(:home),
      list_ids: route_value(:list_ids),
      expected_revision: route_value(:expected_revision)
    )
    redirect_to settings_external_services_rss_path(page_options), notice: I18n.t('external_bridge.feed_routes.saved'), status: :see_other
  rescue ExternalBridge::Error => e
    if e.code == 'stale_feed_routes'
      flash.now[:alert] = I18n.t('external_bridge.feed_routes.stale')
      @page = ExternalServices::RSS.page_for(current_user, page: page_number)
      render template: 'settings/external_services/rss/show', status: :conflict
    else
      redirect_to settings_external_services_rss_path(page_options), alert: failure_alert(e), status: :see_other
    end
  end

  private

  def route_value(key)
    raw = params[:feed_route]
    return nil unless raw.respond_to?(:[])

    raw[key]
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

  def failure_alert(error)
    I18n.t("external_bridge.feed_routes.errors.#{error.code}", default: I18n.t('external_bridge.feed_routes.invalid'))
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
