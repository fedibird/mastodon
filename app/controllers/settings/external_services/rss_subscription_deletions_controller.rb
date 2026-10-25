# frozen_string_literal: true

# Progress card of the signed-in user's own asynchronous RSS unsubscribes.
# Another user's id is a 404, like an id that does not exist. Reading needs no
# fresh challenge (it exposes counters only); a retry does.
class Settings::ExternalServices::RSSSubscriptionDeletionsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_recent_challenge!, only: :retry

  def show
    row = ExternalServices::RSS.deletion_row_for(current_user, params[:id])
    return head(:not_found) if row.nil?

    render json: row.as_json
  end

  def retry
    ExternalBridge::RSS::SubscriptionDeletionRetry.new.call(user: current_user, deletion_id: params[:id])
    redirect_to settings_external_services_rss_path, status: :see_other
  rescue ExternalBridge::Error
    redirect_to settings_external_services_rss_path, alert: I18n.t('external_bridge.errors.not_found'), status: :see_other
  end

  private

  def require_recent_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    redirect_to settings_external_services_rss_path, status: :see_other
  end
end
