# frozen_string_literal: true

class Api::V1::Accounts::StatusesController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :set_account

  after_action :insert_pagination_headers, unless: -> { truthy_param?(:pinned) }

  def index
    @statuses = truthy_param?(:fetch) ? fetch_statuses : load_statuses

    if compact?
      render json: CompactStatusesPresenter.new(statuses: @statuses), serializer: REST::CompactStatusesSerializer, application_name: doorkeeper_token&.application&.name
    else
      account_ids = @statuses.filter(&:quote?).map { |status| status.quote.account_id }.uniq

      render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id), account_relationships: AccountRelationshipsPresenter.new(account_ids, current_user&.account_id), application_name: doorkeeper_token&.application&.name
    end
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end

  def load_statuses
    @account.suspended? ? [] : cached_account_statuses
  end

  def cached_account_statuses
    statuses = truthy_param?(:pinned) ? pinned_scope : permitted_account_statuses

    statuses.merge!(only_media_scope)  if truthy_param?(:only_media)
    statuses.merge!(no_replies_scope)  if truthy_param?(:exclude_replies)
    statuses.merge!(no_reblogs_scope)  if truthy_param?(:exclude_reblogs)
    statuses.merge!(hashtag_scope)     if params[:tagged].present?
    statuses.merge!(no_personal_scope) if current_user&.setting_hide_personal_from_account

    cache_collection_paginated_by_id(
      statuses,
      Status,
      limit_param(DEFAULT_STATUSES_LIMIT),
      params_slice(:max_id, :since_id, :min_id)
    )
  end

  def fetch_statuses
    @account.suspended? || current_account.nil? || !current_account.following?(@account) ? [] : cached_fetch_account_statuses
  end

  def cached_fetch_account_statuses
    statuses = ActivityPub::FetchOutboxService.new.call(@account, limit: limit_param(DEFAULT_STATUSES_LIMIT))&.permitted_for(@account, current_account) || Status.none

    statuses.merge!(only_media_scope)  if truthy_param?(:only_media)
    statuses.merge!(no_replies_scope)  if truthy_param?(:exclude_replies)
    statuses.merge!(no_reblogs_scope)  if truthy_param?(:exclude_reblogs)
    statuses.merge!(hashtag_scope)     if params[:tagged].present?
    statuses.merge!(no_personal_scope) if current_user&.setting_hide_personal_from_account

    cache_collection(statuses, Status)
  end

  def permitted_account_statuses
    @account.permitted_statuses(current_account)
  end

  def compact?
    truthy_param?(:compact)
  end

  def only_media_scope
    Status.include_expired.joins(:media_attachments).merge(@account.media_attachments.reorder(nil)).distinct
  end

  def pinned_scope
    @account.pinned_statuses.permitted_for(@account, current_account)
  end

  def no_replies_scope
    Status.include_expired.without_replies
  end

  def no_reblogs_scope
    Status.include_expired.without_reblogs
  end

  def hashtag_scope
    tag = Tag.find_normalized(params[:tagged])

    if tag
      Status.include_expired.tagged_with(tag.id)
    else
      Status.none
    end
  end

  def no_personal_scope
    Status.include_expired.without_personal_visibility
  end

  def pagination_params(core_params)
    params.slice(:limit, :only_media, :exclude_replies, :compact).permit(:limit, :only_media, :exclude_replies, :compact).merge(core_params)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def next_path
    if records_continue?
      api_v1_account_statuses_url pagination_params(max_id: pagination_max_id)
    end
  end

  def prev_path
    unless @statuses.empty?
      api_v1_account_statuses_url pagination_params(min_id: pagination_since_id)
    end
  end

  def records_continue?
    @statuses.size == limit_param(DEFAULT_STATUSES_LIMIT)
  end

  def pagination_max_id
    @statuses.last.id
  end

  def pagination_since_id
    @statuses.first.id
  end
end
