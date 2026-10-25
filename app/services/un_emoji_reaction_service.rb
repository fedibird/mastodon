# frozen_string_literal: true

class UnEmojiReactionService < BaseService
  include Payloadable

  def call(account, status, emoji, **options)
    @account          = account
    shortcode, domain = emoji&.split('@')
    domain = nil if domain == Rails.configuration.x.local_domain

    status = EmojiReactionCapability::WriteTarget.resolve(status)

    if shortcode
      if options[:shortcode_only]
        emoji_reactions = EmojiReaction.where(account: account, status: status, name: shortcode)
      else
        custom_emoji    = CustomEmoji.find_by(shortcode: shortcode, domain: domain)
        emoji_reactions = EmojiReaction.where(account: account, status: status, name: shortcode, custom_emoji: custom_emoji)
      end
    else
      emoji_reactions = EmojiReaction.where(account: account, status: status)
    end

    emoji_reactions.each do |emoji_reaction|
      create_notification(emoji_reaction)
      emoji_reaction.destroy!
    end
  end

  private

  def create_notification(emoji_reaction)
    status = emoji_reaction.status

    if status.account.local?
      ActivityPub::CustomEmojiDistributionWorker.new.perform(emoji_reaction.id, 'delete')
    elsif status.account.activitypub?
      type = emoji_reaction.unicode? && status.account.node.features(:emoji_reaction_type) == 'unicode' ? 'EmojiReact' : 'Like'
      ActivityPub::DeliveryWorker.perform_async(build_json(emoji_reaction, type), emoji_reaction.account_id, status.account.inbox_url)
      EmojiReactionCapability::Shadow.observe_undo(emoji_reaction, legacy_type: type)
    else
      EmojiReactionCapability::Shadow.observe_undo(emoji_reaction, legacy_type: nil)
    end
  end

  def build_json(emoji_reaction, type)
    Oj.dump(serialize_payload(emoji_reaction, ActivityPub::UndoEmojiReactionSerializer, signer: @account, type: type))
  end
end
