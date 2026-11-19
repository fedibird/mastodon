# frozen_string_literal: true

class Api::V1::FavouritesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:favourites' }
  before_action :require_user!
  after_action :insert_pagination_headers

  def index
    @statuses = load_statuses

    if compact?
      render json: CompactStatusesPresenter.new(statuses: @statuses), serializer: REST::CompactStatusesSerializer, application_name: doorkeeper_token&.application&.name
    else
      account_ids = @statuses.filter(&:quote?).map { |status| status.quote.account_id }.uniq

      render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id), account_relationships: AccountRelationshipsPresenter.new(account_ids, current_user&.account_id), application_name: doorkeeper_token&.application&.name
    end
  end

  private

  def load_statuses
    cached_favourites
  end

  def cached_favourites
    cache_collection(results.map(&:status), Status)
  end

  # The Status scope merged for visibility/media checks includes
  # statuses.id DESC via Status.default_scope. Clear that order before
  # pagination so the returned page follows the collection record id.
  def results
    @_results ||= if status_order?
                    status_ordered_results(filtered_account_favourites)
                  else
                    # Status.default_scope orders by statuses.id DESC; the projection
                    # privacy merge can bring that order into this relation.
                    # Clear it so record-id pagination and the visible order agree.
                    filtered_account_favourites.reorder(nil).to_a_paginated_by_id(
                      limit_param(DEFAULT_STATUSES_LIMIT),
                      params_slice(:max_id, :since_id, :min_id)
                    )
                  end
  end

  # The default cursor is the collection record id (added order). Status
  # ordering uses a different cursor and must be paginated in the database,
  # never by sorting an already-loaded page in the WebUI.
  def status_ordered_results(scope)
    status_id = Favourite.arel_table[:status_id]
    page = params_slice(:max_id, :since_id, :min_id)
    scope = scope.where(status_id.lt(page[:max_id])) if page[:max_id].present?
    scope = scope.where(status_id.gt(page[:since_id])) if page[:since_id].present?
    scope = scope.where(status_id.gt(page[:min_id])) if page[:min_id].present?

    # A post can have multiple media attachments; the media join must not
    # consume several positions in one status-ordered page.
    scope = scope.distinct if media_only?

    ascending = page[:min_id].present?
    records = scope.reorder(ascending ? status_id.asc : status_id.desc).limit(limit_param(DEFAULT_STATUSES_LIMIT)).to_a
    ascending ? records.reverse : records
  end

  def status_order?
    params[:order] == 'status'
  end

  def filtered_account_favourites
    account_favourites.joins(:status).eager_load(:status).merge(ExternalBridge::ProjectionPrivacy.visible_status_relation(current_user.id)).tap do |scope|
      scope.merge!(media_only_scope)    if media_only?
      scope.merge!(without_media_scope) if without_media?
    end
  end

  def account_favourites
    current_account.favourites
  end

  def media_only?
    truthy_param?(:only_media)
  end

  def without_media?
    truthy_param?(:without_media)
  end

  def compact?
    truthy_param?(:compact)
  end

  def media_only_scope
    Status.joins(:media_attachments)
  end

  def without_media_scope
    Status.left_joins(:media_attachments).where(media_attachments: {status_id: nil})
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def next_path
    if records_continue?
      api_v1_favourites_url pagination_params(max_id: pagination_max_id)
    end
  end

  def prev_path
    unless results.empty?
      api_v1_favourites_url pagination_params(min_id: pagination_since_id)
    end
  end

  def pagination_max_id
    status_order? ? results.last.status_id : results.last.id
  end

  def pagination_since_id
    status_order? ? results.first.status_id : results.first.id
  end

  def records_continue?
    results.size == limit_param(DEFAULT_STATUSES_LIMIT)
  end

  def pagination_params(core_params)
    params_slice(:limit, :compact, :only_media, :without_media, :order).merge(core_params)
  end
end
