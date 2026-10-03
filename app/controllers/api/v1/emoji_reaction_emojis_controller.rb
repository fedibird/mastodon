# frozen_string_literal: true

class Api::V1::EmojiReactionEmojisController < Api::BaseController
  # Kept statuses only. EmojiReaction#status unscope(where: :expired_at),
  # so expired statuses stay, matching GET /api/v1/emoji_reactions.
  AGGREGATE_ORDER_SQL = <<~SQL.squish.freeze
    COUNT(*) DESC,
    MAX(emoji_reactions.created_at) DESC,
    emoji_reactions.name ASC,
    emoji_reactions.custom_emoji_id ASC
  SQL

  before_action -> { doorkeeper_authorize! :read, :'read:favourites' }
  before_action :require_user!

  def index
    render json: emoji_catalog, each_serializer: REST::EmojiReactionEmojiSerializer
  end

  private

  def emoji_catalog
    rows = aggregated_emoji_rows
    custom_emojis = custom_emojis_for(rows)

    rows.map do |name, custom_emoji_id, count, last_used_at|
      EmojiReactionEmojiPresenter.new(
        name: name,
        custom_emoji_id: custom_emoji_id,
        count: count,
        last_used_at: last_used_at,
        custom_emoji: custom_emojis[custom_emoji_id]
      )
    end
  end

  # current_account.emoji_reactions applies account_id before GROUP BY.
  def aggregated_emoji_rows
    current_account.emoji_reactions
                   .joins(:status)
                   .group(:name, :custom_emoji_id)
                   .reorder(Arel.sql(AGGREGATE_ORDER_SQL))
                   .pluck(
                     Arel.sql('emoji_reactions.name'),
                     Arel.sql('emoji_reactions.custom_emoji_id'),
                     Arel.sql('COUNT(*)'),
                     Arel.sql('MAX(emoji_reactions.created_at)')
                   )
  end

  def custom_emojis_for(rows)
    ids = rows.filter_map { |_name, custom_emoji_id, _count, _last_used_at| custom_emoji_id }.uniq
    return {} if ids.empty?

    CustomEmoji.where(id: ids).index_by(&:id)
  end
end
