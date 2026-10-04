# frozen_string_literal: true

module CustomEmojiReactionCache
  extend ActiveSupport::Concern

  # Attributes that change REST::GroupedEmojiReactionSerializer output, plus shortcode.
  # disabled also decides whether a reaction is included via EmojiReaction.enabled.
  # image_storage_schema_version changes the Paperclip prefix used for url and static_url.
  REACTION_CACHE_ATTRIBUTES = %w(
    disabled
    shortcode
    domain
    width
    height
    alternate_name
    ruby
    image_file_name
    image_content_type
    image_file_size
    image_updated_at
    image_remote_url
    image_storage_schema_version
  ).freeze

  included do
    before_update :remember_emoji_reaction_cache_invalidation, if: :emoji_reaction_cache_attributes_changing?
    before_destroy :mark_emoji_reaction_caches_dirty
    after_commit :invalidate_emoji_reaction_caches_after_update, on: :update
    after_commit :enqueue_dirty_emoji_reaction_cache_refresh, on: :destroy
    after_rollback :clear_emoji_reaction_cache_invalidation_flag
  end

  private

  # Snapshot the affected statuses only after this update commits. A reaction
  # that committed while the update was in flight is then visible to the
  # set-based query. A reaction that commits later refreshes itself.
  def remember_emoji_reaction_cache_invalidation
    @emoji_reaction_cache_invalidated = true
  end

  def invalidate_emoji_reaction_caches_after_update
    return unless @emoji_reaction_cache_invalidated

    clear_emoji_reaction_cache_invalidation_flag

    EmojiReactionCacheInvalidator.mark_for_custom_emoji_ids(id)
    RefreshDirtyEmojiReactionCachesWorker.perform_async
  rescue StandardError
    # after_commit runs after the emoji row is committed, so a failed mark
    # cannot roll the new metadata back. Retry by id; the same attribute
    # values will not look changed on a later save.
    PostProcessEmojiReactionCacheWorker.perform_async([id])
    raise
  end

  def mark_emoji_reaction_caches_dirty
    lock_custom_emoji_for_destroy!
    # Reactions still exist here, before custom_emoji_id ON DELETE CASCADE.
    # The row lock above is held until the destroy transaction commits, so an
    # insert that references this emoji cannot commit in between the snapshot
    # and the DELETE.
    return unless EmojiReaction.exists?(custom_emoji_id: id)

    EmojiReactionCacheInvalidator.mark_for_custom_emoji_ids(id)
    @emoji_reaction_cache_invalidated = true
  end

  def lock_custom_emoji_for_destroy!
    locked_id = self.class.where(id: id).lock('FOR UPDATE').pick(:id)
    return if locked_id.present?

    raise ActiveRecord::RecordNotFound, "Couldn't lock CustomEmoji #{id}"
  end

  def enqueue_dirty_emoji_reaction_cache_refresh
    return unless @emoji_reaction_cache_invalidated

    clear_emoji_reaction_cache_invalidation_flag
    RefreshDirtyEmojiReactionCachesWorker.perform_async
  end

  def clear_emoji_reaction_cache_invalidation_flag
    return if frozen?

    @emoji_reaction_cache_invalidated = false
  end

  def emoji_reaction_cache_attributes_changing?
    REACTION_CACHE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end
end
