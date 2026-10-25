# frozen_string_literal: true

# Creates a list for the signed-in user from the destination picker. It does
# not read or write any feed route; saving destinations stays with
# RSSFeedRoutesController and ExternalBridge::FeedRoutes::Update.
class Settings::ExternalServices::FeedRouteListsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_json_challenge!

  def create
    return render_error(:disabled, :forbidden) unless ExternalBridge::Feeds::Feature.permitted?(current_user)

    result = ExternalServices::CreateFeedRouteList.new.call(user: current_user, title: requested_title)
    return render_error(result.error, :unprocessable_entity) if result.error

    list = result.list
    render json: { id: list.id.to_s, title: list.title, message: I18n.t('external_bridge.feed_routes.list_created', title: list.title) }, status: :created
  end

  private

  def requested_title
    raw = params[:list]
    return '' unless raw.is_a?(ActionController::Parameters)

    raw[:title].to_s
  end

  def render_error(code, status)
    render json: { error: I18n.t("external_bridge.feed_routes.list_errors.#{code}") }, status: status
  end

  def require_json_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    render_error(:challenge, :forbidden)
  end
end
