# frozen_string_literal: true

class Api::V1::EmojiReactionsController < Api::BaseController
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
    cached_emoji_reactions
  end

  def cached_emoji_reactions
    cache_collection(results.map(&:status), Status)
  end

  def results
    @_results ||= filtered_emoji_reactions.to_a_paginated_by_id(
      limit_param(DEFAULT_STATUSES_LIMIT),
      params_slice(:max_id, :since_id, :min_id)
    )
  end

  def filtered_emoji_reactions
    account_emoji_reactions.joins(:status).eager_load(:status).tap do |emoji_reactions|
      emoji_reactions.merge!(emojis_scope)        if emojis_requested?
      emoji_reactions.merge!(media_only_scope)    if media_only?
      emoji_reactions.merge!(without_media_scope) if without_media?
    end
  end

  def account_emoji_reactions
    EmojiReaction.where(id: current_account.emoji_reactions.group(:status_id).select('min(id)'))
  end

  def emojis_requested?
    emoji_reactions_params[:emojis].present?
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

  def emojis_scope
    emoji_reactions = EmojiReaction.none

    emoji_reactions_params[:emojis].each do |emoji|
      shortcode, domain = emoji.split('@')
                 domain = nil if domain == Rails.configuration.x.local_domain

      custom_emoji = CustomEmoji.find_by(shortcode: shortcode, domain: domain)

      emoji_reactions = emoji_reactions.or(EmojiReaction.where(name: shortcode, custom_emoji: custom_emoji))
    end

    emoji_reactions
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
    api_v1_emoji_reactions_url pagination_params(max_id: pagination_max_id) if records_continue?
  end

  def prev_path
    api_v1_emoji_reactions_url pagination_params(min_id: pagination_since_id) unless results.empty?
  end

  def pagination_max_id
    results.last.id
  end

  def pagination_since_id
    results.first.id
  end

  def records_continue?
    results.size == limit_param(DEFAULT_STATUSES_LIMIT)
  end

  def pagination_params(core_params)
    params_slice(:limit, :compact, :only_media, :without_media).merge(core_params)
  end

  def emoji_reactions_params
    params.permit(emojis: [])
  end
end
