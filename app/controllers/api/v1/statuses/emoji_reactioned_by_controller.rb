# frozen_string_literal: true

class Api::V1::Statuses::EmojiReactionedByController < Api::BaseController
  include Authorization

  before_action -> { authorize_if_got_token! :read, :'read:favourites' }
  before_action :set_status
  after_action :insert_pagination_headers

  def index
    @emoji_reactions = load_emoji_reactions
    render json: @emoji_reactions, each_serializer: REST::EmojiReactionSerializer
  end

  private

  def load_emoji_reactions
    scope = default_emoji_reactions
    scope = scope.where.not(account_id: current_account.excluded_from_timeline_account_ids) unless current_account.nil?
    scope = EmojiMutes::RuleSet.for(current_account&.id).filter_reactions(scope)
    scope.merge(paginated_emoji_reactions).to_a
  end

  def default_emoji_reactions
    return EmojiReaction.none if current_user&.setting_hide_list_of_emoji_reactions_to_posts

    EmojiReaction.enabled.where(status_id: @status.id)
  end

  def paginated_emoji_reactions
    EmojiReaction.paginate_by_max_id(
      limit_param(DEFAULT_ACCOUNTS_LIMIT),
      params[:max_id],
      params[:since_id]
    )
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def next_path
    if records_continue?
      api_v1_status_emoji_reactioned_by_index_url pagination_params(max_id: pagination_max_id)
    end
  end

  def prev_path
    unless @emoji_reactions.empty?
      api_v1_status_emoji_reactioned_by_index_url pagination_params(since_id: pagination_since_id)
    end
  end

  def pagination_max_id
    @emoji_reactions.last.id
  end

  def pagination_since_id
    @emoji_reactions.first.id
  end

  def records_continue?
    @emoji_reactions.size == limit_param(DEFAULT_ACCOUNTS_LIMIT)
  end

  def set_status
    @status = Status.include_expired.find(params[:status_id])
    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    not_found
  end

  def pagination_params(core_params)
    params.slice(:limit).permit(:limit).merge(core_params)
  end
end
