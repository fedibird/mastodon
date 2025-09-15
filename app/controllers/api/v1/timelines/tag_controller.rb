# frozen_string_literal: true

class Api::V1::Timelines::TagController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :require_user!, if: :require_auth?
  before_action :load_tag
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

  def load_tag
    @tag = Tag.find_normalized(params[:id])
  end

  def load_statuses
    cached_tagged_statuses
  end

  def cached_tagged_statuses
    @tag.nil? ? [] : cache_collection(tag_timeline_statuses, Status)
  end

  def tag_timeline_statuses
    tag_feed.get(
      limit_param(DEFAULT_STATUSES_LIMIT),
      params[:max_id],
      params[:since_id],
      params[:min_id]
    )
  end

  def tag_feed
    TagFeed.new(
      @tag,
      current_account,
      any: params[:any],
      all: params[:all],
      none: params[:none],
      local: false,
      remote: truthy_param?(:remote),
      only_media: truthy_param?(:only_media),
      without_media: truthy_param?(:without_media),
      without_bot: without_bot?
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
    params.slice(:limit, :only_media, :without_media, :without_bot).permit(:limit, :only_media, :without_media, :without_bot).merge(core_params)
  end

  def next_path
    api_v1_timelines_tag_url params[:id], pagination_params(max_id: pagination_max_id)
  end

  def prev_path
    api_v1_timelines_tag_url params[:id], pagination_params(min_id: pagination_since_id)
  end

  def pagination_max_id
    @statuses.last.id
  end

  def pagination_since_id
    @statuses.first.id
  end
end
