# frozen_string_literal: true

class AccountsController < ApplicationController
  PAGE_SIZE     = 20
  PAGE_SIZE_MAX = 200

  include AccountControllerConcern
  include SignatureAuthentication

  before_action :require_signature!, if: -> { request.format == :json && authorized_fetch_mode? }
  before_action :set_cache_headers
  before_action :set_body_classes

  skip_around_action :set_locale, if: -> { [:json, :rss].include?(request.format&.to_sym) }
  skip_before_action :require_functional!, unless: :whitelist_mode?

  def show
    respond_to do |format|
      format.html do
        expires_in 0, public: true unless user_signed_in?

        @pinned_statuses   = []
        @endorsed_accounts = @account.endorsed_accounts.to_a.sample(4)
        @featured_hashtags = @account.featured_tags.order(statuses_count: :desc)

        if current_account && @account.blocking?(current_account)
          @statuses = []
          return
        end

        @pinned_statuses = cached_filtered_status_pins if show_pinned_statuses?
        @statuses        = cached_filtered_status_page
        @rss_url         = rss_url

        assign_pagination_urls
      end

      format.rss do
        expires_in 1.minute, public: true

        limit     = params[:limit].present? ? [params[:limit].to_i, PAGE_SIZE_MAX].min : PAGE_SIZE
        @statuses = filtered_statuses.without_reblogs.limit(limit)
        @statuses = cache_collection(@statuses, Status)
        render xml: RSS::AccountSerializer.render(@account, @statuses, params[:tag])
      end

      format.json do
        expires_in 3.minutes, public: !(authorized_fetch_mode? && signed_request_account.present?)
        render_with_cache json: @account, content_type: 'application/activity+json', serializer: ActivityPub::ActorSerializer, adapter: ActivityPub::Adapter
      end
    end
  end

  private

  def set_body_classes
    @body_classes = 'with-modals'
  end

  def show_pinned_statuses?
    [replies_requested?, media_requested?, tag_requested?, params[:max_id].present?, params[:min_id].present?].none?
  end

  def filtered_pinned_statuses
    @account.pinned_statuses.where(visibility: [:public, :unlisted])
  end

  def filtered_statuses
    default_statuses.tap do |statuses|
      statuses.merge!(hashtag_scope)    if tag_requested?
      statuses.merge!(only_media_scope) if media_requested?
      statuses.merge!(no_replies_scope) unless replies_requested?
    end
  end

  def default_statuses
    @account.statuses.where(visibility: [:public, :unlisted])
  end

  def only_media_scope
    Status.joins(:media_attachments).merge(@account.media_attachments.reorder(nil)).group(:id)
  end

  def no_replies_scope
    Status.without_replies
  end

  def hashtag_scope
    if requested_tag
      Status.tagged_with(requested_tag.id)
    else
      Status.none
    end
  end

  # Nil is memoized so the page query and the older/newer probes share one lookup.
  def requested_tag
    return @requested_tag if defined?(@requested_tag)

    @requested_tag = Tag.find_normalized(params[:tag])
  end

  # Tagged media keeps the media_attachments join, same as the REST only_media path.
  def tagged_id_first_eligible?
    tag_requested? && !media_requested?
  end

  def tagged_statuses_page(limit, page)
    return [] if requested_tag.nil?

    AccountStatusesTaggedQuery.new(
      candidate_scope: default_statuses,
      tag_id: requested_tag.id,
      limit: limit,
      page: page,
      filter_after_intersection: true,
      filters: {
        exclude_replies: !replies_requested?,
        exclude_reblogs: false,
      }
    ).records
  end

  def tagged_status_before?(status_id)
    tagged_statuses_page(1, { max_id: status_id }).present?
  end

  def tagged_status_after?(status_id)
    tagged_statuses_page(1, { min_id: status_id }).present?
  end

  def username_param
    params[:username]
  end

  def skip_temporary_suspension_response?
    request.format == :json
  end

  def rss_url
    if tag_requested?
      short_account_tag_url(@account, params[:tag], format: 'rss')
    else
      short_account_url(@account, format: 'rss')
    end
  end

  def older_url
    pagination_url(max_id: @statuses.last.id)
  end

  def newer_url
    pagination_url(min_id: @statuses.first.id)
  end

  def pagination_url(max_id: nil, min_id: nil)
    if tag_requested? && media_requested?
      short_account_tag_media_url(@account, params[:tag], max_id: max_id, min_id: min_id)
    elsif tag_requested?
      short_account_tag_url(@account, params[:tag], max_id: max_id, min_id: min_id)
    elsif media_requested?
      short_account_media_url(@account, max_id: max_id, min_id: min_id)
    elsif replies_requested?
      short_account_with_replies_url(@account, max_id: max_id, min_id: min_id)
    else
      short_account_url(@account, max_id: max_id, min_id: min_id)
    end
  end

  def media_requested?
    request.path.split('.').first.end_with?('/media')
  end

  def replies_requested?
    request.path.split('.').first.end_with?('/with_replies') && !tag_requested?
  end

  def tag_requested?
    request.path.split('.').first.delete_suffix('/media').end_with?(Addressable::URI.parse("/tagged/#{params[:tag]}").normalize)
  end

  def cached_filtered_status_pins
    cache_collection(
      filtered_pinned_statuses,
      Status
    )
  end

  def assign_pagination_urls
    return if @statuses.empty?

    if tagged_id_first_eligible?
      @older_url = older_url if tagged_status_before?(@statuses.last.id)
      @newer_url = newer_url if tagged_status_after?(@statuses.first.id)
    else
      @older_url = older_url if @statuses.last.id > filtered_statuses.last.id
      @newer_url = newer_url if @statuses.first.id < filtered_statuses.first.id
    end
  end

  def cached_filtered_status_page
    page = params_slice(:max_id, :min_id, :since_id)

    if tagged_id_first_eligible?
      cache_collection(tagged_statuses_page(PAGE_SIZE, page), Status)
    elsif page[:min_id].present? && profile_min_id_page?
      cache_collection(profile_statuses_after_min_id(page), Status)
    else
      cache_collection_paginated_by_id(filtered_statuses, Status, PAGE_SIZE, page)
    end
  end

  # `id > min_id` alone lets the planner walk statuses_pkey. With account_id
  # fixed, a tuple lower bound is the same predicate and can use
  # index_statuses_20251001. Non-media tagged HTML uses
  # AccountStatusesTaggedQuery. Tagged media stays on the generic paginator.
  def profile_min_id_page?
    !tag_requested? && !media_requested?
  end

  def profile_statuses_after_min_id(page)
    scope = filtered_statuses.where(
      '(statuses.account_id, statuses.id) > (?, ?)',
      @account.id,
      Integer(page[:min_id])
    )
    scope = scope.where(Status.arel_table[:id].lt(Integer(page[:max_id]))) if page[:max_id].present?
    scope.reorder(account_id: :asc, id: :asc).limit(PAGE_SIZE).reverse
  end

  def params_slice(*keys)
    params.slice(*keys).permit(*keys)
  end
end
