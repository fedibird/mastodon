# frozen_string_literal: true

class Api::V1::Timelines::HomeController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }, only: [:show]
  before_action :require_user!, only: [:show]
  after_action :insert_pagination_headers, unless: -> { @statuses.empty? }

  def show
    @statuses = load_statuses

    if compact?
      render json: CompactStatusesPresenter.new(statuses: @statuses), serializer: REST::CompactStatusesSerializer, application_name: doorkeeper_token&.application&.name, status: account_home_feed.regenerating? ? 206 : 200
    else
      account_ids = @statuses.filter(&:quote?).map { |status| status.quote.account_id }.uniq

      render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id), account_relationships: AccountRelationshipsPresenter.new(account_ids, current_user&.account_id), application_name: doorkeeper_token&.application&.name, status: account_home_feed.regenerating? ? 206 : 200
    end
  end

  private

  def load_statuses
    cached_home_statuses
  end

  def cached_home_statuses
    cache_collection home_statuses, Status
  end

  def home_statuses
    feed = account_home_feed
    limit = limit_param(DEFAULT_STATUSES_LIMIT)
    if ExternalBridge::Feeds::Feature.permitted?(current_user)
      ExternalBridge::Feeds::Compose.new(user: current_user, feed: feed, destination: 'home').call(
        limit,
        params[:max_id],
        params[:since_id],
        params[:min_id],
        visibilities
      )
    else
      feed.get(limit, params[:max_id], params[:since_id], params[:min_id], visibilities)
    end
  end

  def account_home_feed
    HomeFeed.new(current_account)
  end

  def compact?
    truthy_param?(:compact)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def pagination_params(core_params)
    permitted = params.slice(:local, :limit, :visibilities).permit(:local, :limit, visibilities: [])
    permitted[:compact] = params[:compact] if truthy_param?(:compact)
    permitted.merge(core_params)
  end

  def next_path
    api_v1_timelines_home_url pagination_params(max_id: pagination_max_id)
  end

  def prev_path
    api_v1_timelines_home_url pagination_params(min_id: pagination_since_id)
  end

  def pagination_max_id
    @statuses.last.id
  end

  def pagination_since_id
    @statuses.first.id
  end

  def visibilities
    val = params.permit(visibilities: [])[:visibilities] || []
    val = [val] unless val.is_a?(Enumerable)
    val
  end
end
