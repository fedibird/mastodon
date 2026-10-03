# frozen_string_literal: true

class Api::V1::EmojiReactionsController < Api::BaseController
  # Overscan so a batch of discarded statuses does not end the page early.
  # Specs stub representative_batch_size to force the follow-up scan.
  REPRESENTATIVE_BATCH_SIZE = 100

  # A row is the representative when no earlier reaction exists for the same
  # account and status. That id is the same value as MIN(emoji_reactions.id).
  REPRESENTATIVE_NOT_EXISTS_SQL = <<~SQL.squish.freeze
    NOT EXISTS (
      SELECT 1
      FROM emoji_reactions earlier
      WHERE earlier.account_id = emoji_reactions.account_id
        AND earlier.status_id = emoji_reactions.status_id
        AND earlier.id < emoji_reactions.id
    )
  SQL

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
    @_results ||= if legacy_media_filter?
                    filtered_emoji_reactions.to_a_paginated_by_id(
                      limit_param(DEFAULT_STATUSES_LIMIT),
                      params_slice(:max_id, :since_id, :min_id)
                    )
                  else
                    limited_representative_emoji_reactions
                  end
  end

  # Media filters stay on the pre-existing grouped query. emojis[] uses the
  # bounded representative scan so a later reaction can match without
  # becoming the pagination id.
  def legacy_media_filter?
    !emojis_requested? && (media_only? || without_media?)
  end

  # Walk representative ids in index order. Status visibility is applied to
  # each bounded batch, and the next batch continues after the last scanned
  # candidate so a fully discarded batch cannot stall the cursor.
  def limited_representative_emoji_reactions
    limit = limit_param(DEFAULT_STATUSES_LIMIT)
    page = params_slice(:max_id, :since_id, :min_id)
    ascending = page[:min_id].present?
    batch_size = representative_batch_size
    lower_id = ascending ? page[:min_id] : page[:since_id]
    upper_id = page[:max_id]
    collected = []

    loop do
      candidate_ids = representative_candidate_ids(batch_size: batch_size, ascending: ascending, lower_id: lower_id, upper_id: upper_id)
      break if candidate_ids.empty?

      if ascending
        lower_id = candidate_ids.last
      else
        upper_id = candidate_ids.last
      end

      collected.concat(kept_representative_reactions(candidate_ids))
      break if collected.size >= limit || candidate_ids.size < batch_size
    end

    page_reactions = collected.take(limit)
    ascending ? page_reactions.reverse : page_reactions
  end

  def representative_batch_size
    REPRESENTATIVE_BATCH_SIZE
  end

  def representative_candidate_ids(batch_size:, ascending:, lower_id:, upper_id:)
    scope = current_account.emoji_reactions.where(Arel.sql(REPRESENTATIVE_NOT_EXISTS_SQL))
    scope = scope.where(matching_emoji_exists_node) if emojis_requested?
    scope = scope.where(EmojiReaction.arel_table[:id].gt(lower_id)) if lower_id.present?
    scope = scope.where(EmojiReaction.arel_table[:id].lt(upper_id)) if upper_id.present?
    scope = ascending ? scope.order(id: :asc) : scope.order(id: :desc)
    scope.limit(batch_size).pluck(:id)
  end

  def kept_representative_reactions(ids)
    scope = EmojiReaction.where(id: ids).joins(:status).eager_load(:status)
    scope = scope.merge(media_only_scope) if media_only?
    scope = scope.merge(without_media_scope) if without_media?
    reactions = scope.index_by { |reaction| reaction.id.to_i }
    ids.filter_map { |id| reactions[id.to_i] }
  end

  def filtered_emoji_reactions
    account_emoji_reactions.joins(:status).eager_load(:status).tap do |emoji_reactions|
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

  # The representative row only defines order. emojis[] matches when any
  # current reaction on the same account and status has one of the requested
  # identities. Repeated parameters collapse to one identity.
  def matching_emoji_exists_node
    identities = requested_emoji_identities
    return Arel.sql('1 = 0') if identities.empty?

    matching = EmojiReaction.arel_table.alias('matching')
    representative = EmojiReaction.arel_table
    predicate = identities.map { |identity| emoji_identity_predicate(matching, identity) }.reduce { |left, right| left.or(right) }
    match = Arel::SelectManager.new
    match.from(matching)
    match.project(Arel.sql('1'))
    match.where(
      matching[:account_id].eq(representative[:account_id]).and(
        matching[:status_id].eq(representative[:status_id]).and(Arel::Nodes::Grouping.new(predicate))
      )
    )

    Arel::Nodes::Exists.new(match)
  end

  def emoji_identity_predicate(table, identity)
    Arel::Nodes::Grouping.new(
      table[:name].eq(identity[:name]).and(table[:custom_emoji_id].eq(identity[:custom_emoji_id]))
    )
  end

  def requested_emoji_identities
    return @requested_emoji_identities if defined?(@requested_emoji_identities)

    @requested_emoji_identities = Array(emoji_reactions_params[:emojis]).filter_map { |emoji| emoji_identity(emoji) }.uniq
  end

  def emoji_identity(emoji)
    shortcode, domain = emoji.to_s.split('@', 2)
    return if shortcode.blank?
    return bare_emoji_identity(shortcode) if domain.nil?
    return if domain.blank?

    normalized_domain = domain.downcase
    normalized_domain = nil if normalized_domain == Rails.configuration.x.local_domain.to_s.downcase
    custom_emoji = CustomEmoji.find_by(shortcode: shortcode, domain: normalized_domain)
    return if custom_emoji.nil?

    { name: shortcode, custom_emoji_id: custom_emoji.id }
  end

  def bare_emoji_identity(shortcode)
    custom_emoji = CustomEmoji.find_by(shortcode: shortcode, domain: nil)
    { name: shortcode, custom_emoji_id: custom_emoji&.id }
  end

  def media_only_scope
    Status.joins(:media_attachments)
  end

  def without_media_scope
    Status.left_joins(:media_attachments).where(media_attachments: { status_id: nil })
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
    params_slice(:limit, :compact, :only_media, :without_media).merge(emoji_reactions_params).merge(core_params)
  end

  def emoji_reactions_params
    params.permit(emojis: [])
  end
end
