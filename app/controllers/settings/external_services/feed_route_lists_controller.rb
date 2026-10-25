# frozen_string_literal: true

# Creates a list for the signed-in user from the destination picker. It does
# not read or write any feed route; saving destinations stays with
# RSSFeedRoutesController and ExternalBridge::FeedRoutes::Update.
class Settings::ExternalServices::FeedRouteListsController < Settings::BaseController
  include ChallengableConcern

  TITLE_LIMIT = 128

  before_action :require_json_challenge!

  def create
    return render_error(:disabled, :forbidden) unless ExternalBridge::Feeds::Feature.permitted?(current_user)

    title = requested_title
    return render_error(:blank, :unprocessable_entity) if title.blank?
    return render_error(:too_long, :unprocessable_entity) if title.length > TITLE_LIMIT

    list, error = create_list(title)
    return render_error(error, :unprocessable_entity) if error

    render json: { id: list.id.to_s, title: list.title, message: I18n.t('external_bridge.feed_routes.list_created', title: list.title) }, status: :created
  end

  private

  def create_list(title)
    current_user.with_lock { build_list(current_user.account, title) }
  end

  def build_list(account, title)
    scope = List.where(account_id: account.id)
    return [nil, :limit] if scope.count >= List::PER_ACCOUNT_LIMIT
    return [nil, :duplicate] if scope.exists?(['LOWER(title) = ?', title.downcase])

    list = List.new(account: account, title: title)
    return [list, nil] if list.save

    [nil, list.errors[:base].any? ? :limit : :failed]
  end

  def requested_title
    raw = params[:list]
    return '' unless raw.is_a?(ActionController::Parameters)

    raw[:title].to_s.squish
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
