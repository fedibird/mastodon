# frozen_string_literal: true

class EmojiReactionService < BaseService
  include Authorization
  include Payloadable

  # A lost insert is retried only while the idempotent flag is on. Each
  # attempt re-reads the row the unique index points at. Giving up raises
  # instead of returning success with no row.
  MAX_LOST_INSERT_ATTEMPTS = 3

  def call(account, status, emoji, fallback_confirmation: nil)
    @account                = account
    @requested_status       = status
    @fallback_confirmation  = fallback_confirmation
    @fallback_policy_cleared = false
    @approved_activity_type = nil
    shortcode, domain = emoji.split('@')
    domain = nil if domain == Rails.configuration.x.local_domain

    return if account.nil? || status.nil? || shortcode.nil?

    ExternalBridge::Guards.reject_target!(status)
    write_status = EmojiReactionCapability::WriteTarget.resolve(status)
    # A boost of a projection must not skip the guard that a direct write hits.
    ExternalBridge::Guards.reject_target!(write_status) if write_status.id != status.id

    custom_emoji = CustomEmoji.find_by(shortcode: shortcode, domain: domain)

    return if remote_custom_emoji_unavailable?(write_status, custom_emoji, domain)

    emoji_reaction, newly_reacted = find_or_create_reaction(write_status, shortcode, custom_emoji)

    emoji_reaction.tap { |reaction| apply_create_effects(reaction, newly_reacted) }
  end

  private

  def remote_custom_emoji_unavailable?(status, custom_emoji, domain)
    custom_emoji.present? && domain.present? && EmojiReaction.where(status_id: status.id, custom_emoji_id: custom_emoji.id).blank?
  end

  # Lookup uses the write status. A sequential retry therefore does not
  # validate again. A lost insert (RecordNotUnique) is not a new reaction.
  # With the idempotent flag off, the loser still re-reads with find_by! and
  # still runs the legacy side effects. With it on, the insert sits in a
  # savepoint so the outer transaction stays usable, the loser re-reads, and
  # notification, delivery, friendship, and moderation do not run again.
  # Success is returned only when that re-read finds the row. If it does not,
  # the insert is retried up to MAX_LOST_INSERT_ATTEMPTS and then raises.
  def find_or_create_reaction(write_status, shortcode, custom_emoji)
    attrs = { account_id: @account.id, status_id: write_status.id, name: shortcode }
    attempts = 0

    loop do
      attempts += 1
      existing = EmojiReaction.find_by(attrs)
      return [existing, false] if existing

      # After the row check, so a repeat PUT stays the P1b-1a no-op even when
      # the user has since chosen deny or ask. No extra read when the gate is off.
      authorize_new_fallback!(write_status, shortcode, custom_emoji)

      begin
        return [insert_reaction(attrs, custom_emoji), true]
      rescue ActiveRecord::RecordNotUnique
        recovered = recover_lost_insert(attrs)
        return [recovered, false] if recovered

        raise Mastodon::RaceConditionError unless retry_lost_insert?(attempts)
      end
    end
  end

  def retry_lost_insert?(attempts)
    EmojiReactionCapability::WriteConfig.idempotent_retry? && attempts < MAX_LOST_INSERT_ATTEMPTS
  end

  def insert_reaction(attrs, custom_emoji)
    attributes = attrs.merge(custom_emoji: custom_emoji)
    if EmojiReactionCapability::WriteConfig.idempotent_retry?
      EmojiReaction.transaction(requires_new: true) { EmojiReaction.create!(attributes) }
    else
      EmojiReaction.create!(attributes)
    end
  end

  def recover_lost_insert(attrs)
    if EmojiReactionCapability::WriteConfig.idempotent_retry?
      EmojiReaction.find_by(attrs) || legacy_stored_row(attrs)
    else
      EmojiReaction.find_by!(attrs)
    end
  end

  # before_validation stores a boost on the boosted status, one step, even
  # when the canonical flag is off. The loser's lookup key is still the
  # wrapper id, so the row has to be read where the model wrote it.
  def legacy_stored_row(attrs)
    status = @requested_status
    return if status.nil? || !status.reblog?

    stored_id = status.reblog.id
    return if stored_id == attrs[:status_id]

    EmojiReaction.find_by(attrs.merge(status_id: stored_id))
  end

  def apply_create_effects(emoji_reaction, newly_reacted)
    if newly_reacted || !EmojiReactionCapability::WriteConfig.idempotent_retry?
      create_notification(emoji_reaction)
      bump_potential_friendship(@account, @requested_status)
    end
    record_moderation_reaction!(@requested_status, emoji_reaction) if newly_reacted
  end

  def record_moderation_reaction!(status, emoji_reaction)
    Moderation::EventRecorder.record_interaction(
      actor: @account,
      target: status.account,
      event_type: :reaction,
      status: status,
      source_record: emoji_reaction
    )
  end

  def create_notification(emoji_reaction)
    status = emoji_reaction.status

    NotifyService.new.call(status.account, :emoji_reaction, emoji_reaction) if status.account.local?

    if status.account.silenced?
      EmojiReactionCapability::Shadow.observe_create(emoji_reaction, legacy_type: nil)
      return
    end

    if status.account.local?
      ActivityPub::CustomEmojiDistributionWorker.perform_async(emoji_reaction.id, 'create')
    elsif status.account.activitypub?
      # The gate's type, when it approved this insert, is the legacy choice
      # frozen for this request. Re-reading the node here could enqueue a
      # different activity than the one the policy allowed. Flag off leaves
      # the instance variable nil and uses the same helper on the association.
      type = @approved_activity_type || EmojiReactionCapability::ActualDelivery.legacy_remote_type(status.account.node)
      ActivityPub::DeliveryWorker.perform_async(build_json(emoji_reaction, type), emoji_reaction.account_id, status.account.inbox_url)
      EmojiReactionCapability::Shadow.observe_create(emoji_reaction, legacy_type: type)
    else
      EmojiReactionCapability::Shadow.observe_create(emoji_reaction, legacy_type: nil)
    end
  end

  def authorize_new_fallback!(write_status, shortcode, custom_emoji)
    return if @fallback_policy_cleared
    return unless EmojiReactionCapability::FallbackPolicyConfig.effective?

    activity_type = EmojiReactionCapability::FallbackGate.enforce!(
      reactor: @account,
      status: write_status,
      shortcode: shortcode,
      custom_emoji: custom_emoji,
      confirmation: confirmation_token
    )
    @approved_activity_type = activity_type if activity_type
    @fallback_policy_cleared = true
  end

  # A non-string (an array, a hash) is treated as no token, not as a crash.
  def confirmation_token
    @fallback_confirmation if @fallback_confirmation.is_a?(String)
  end

  def bump_potential_friendship(account, status)
    ActivityTracker.increment('activity:interactions')

    return if account.following?(status.account_id)

    PotentialFriendshipTracker.record(account.id, status.account_id, :emoji_reaction)
  end

  def build_json(emoji_reaction, type)
    Oj.dump(serialize_payload(emoji_reaction, ActivityPub::EmojiReactionSerializer, signer: @account, type: type))
  end
end
