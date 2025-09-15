# frozen_string_literal: true

class Api::V1::Timelines::GroupController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :require_user!, if: :require_auth?
  before_action :load_group
  after_action :insert_pagination_headers, unless: -> { @statuses.empty? }

  def show
    @statuses = load_statuses

    if compact?
      render json: CompactStatusesPresenter.new(statuses: @statuses), serializer: REST::CompactStatusesSerializer, application_name: doorkeeper_token&.application&.name
    else
      account_ids = @statuses.filter(&:quote?).map { |status| status.quote.account_id }.uniq

      render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id), account_relationships: AccountRelationshipsPresenter.new(account_ids, current_user&.account_id), application_name: doorkeeper_token&.application&.name
    end
  end

  private

  def require_auth?
    !Setting.timeline_preview
  end

  def load_group
    @group = Account.groups.find(params[:id])
  end

  def load_statuses
    cached_group_statuses
  end

  def cached_group_statuses
    cache_collection group_statuses, Status
  end

  def group_statuses
    group_feed.get(
      limit_param(DEFAULT_STATUSES_LIMIT),
      params[:max_id],
      params[:since_id],
      params[:min_id]
    )
  end

  def group_feed
    GroupFeed.new(
      @group,
      current_account,
      only_media: truthy_param?(:only_media),
      without_media: truthy_param?(:without_media),
      without_bot: without_bot?,
      tagged: params[:tagged],
      application: doorkeeper_token&.application
    )
  end

  def without_bot?
    true & (params[:without_bot].nil? && current_user&.setting_hide_bot_on_public_timeline || truthy_param?(:without_bot))
  end

  def compact?
    truthy_param?(:compact)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def pagination_params(core_params)
    params.slice(:limit, :only_media, :without_media, :tagged).permit(:limit, :only_media, :without_media, :tagged).merge(core_params)
  end

  def next_path
    api_v1_timelines_group_url params[:id], pagination_params(max_id: pagination_max_id)
  end

  def prev_path
    api_v1_timelines_group_url params[:id], pagination_params(min_id: pagination_since_id)
  end

  def pagination_max_id
    @statuses.last.id
  end

  def pagination_since_id
    @statuses.first.id
  end
end
