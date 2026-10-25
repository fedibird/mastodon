# frozen_string_literal: true

class ActivityPub::CustomEmojiDistributionWorker < ActivityPub::RawDistributionWorker
  include Sidekiq::Worker
  include Payloadable

  sidekiq_options queue: 'push'

  def perform(emoji_reaction_id, action)
    @emoji_reaction  = EmojiReaction.find(emoji_reaction_id)
    @status          = @emoji_reaction.status
    @account         = @emoji_reaction.account
    @serializer      = action == 'delete' ? ActivityPub::UndoEmojiReactionSerializer : ActivityPub::EmojiReactionSerializer
    like_json        = build_json('Like')
    emoji_react_json = build_json('EmojiReact')

    if @emoji_reaction.unicode?
      ActivityPub::DeliveryWorker.push_bulk(like_inboxes) do |inbox_url|
        [like_json, @account.id, inbox_url]
      end

      ActivityPub::DeliveryWorker.push_bulk(emoji_react_inboxes) do |inbox_url|
        [emoji_react_json, @account.id, inbox_url]
      end
    else
      ActivityPub::DeliveryWorker.push_bulk(inboxes) do |inbox_url|
        [like_json, @account.id, inbox_url]
      end
    end

    # ActivityPub::DeliveryWorker.push_bulk(Relay.enabled.pluck(:inbox_url)) do |inbox_url|
    #   [like_json, @account.id, inbox_url]
    # end

    EmojiReactionCapability::Shadow.observe_fanout(@emoji_reaction, action: action)
  rescue ActiveRecord::RecordNotFound
    true
  end

  private

  def receivers
    if @status.follower_visibility?
      Account.union(@account.delivery_followers).union(Account.remote.joins(:mentions).merge(@status.mentions))
    elsif @status.limited_visibility? || @status.direct_visibility?
      Account.remote.joins(:mentions).merge(@status.mentions)
    else
      Account.none
    end
  end

  def inboxes
    receivers.joins(:node).merge(Node.where("info->>'emoji_reaction_type' != 'none'")).inboxes
  end

  def like_inboxes
    receivers.joins(:node).merge(Node.where("info->>'emoji_reaction_type' = 'custom'")).inboxes
  end

  def emoji_react_inboxes
    receivers.joins(:node).merge(Node.where("info->>'emoji_reaction_type' = 'unicode'")).inboxes
  end

  def build_json(type)
    Oj.dump(serialize_payload(@emoji_reaction, @serializer, signer: @account, type: type))
  end
end
