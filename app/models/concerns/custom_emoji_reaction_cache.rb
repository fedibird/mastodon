# frozen_string_literal: true

module CustomEmojiReactionCache
  extend ActiveSupport::Concern

  # Attributes copied into REST::GroupedEmojiReactionSerializer, plus shortcode.
  # disabled also decides whether a reaction is included via EmojiReaction.enabled.
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
  ).freeze

  included do
    before_update :mark_emoji_reaction_caches_dirty, if: :emoji_reaction_cache_attributes_changing?
    before_destroy :mark_emoji_reaction_caches_dirty
    after_commit :enqueue_dirty_emoji_reaction_cache_refresh, on: [:update, :destroy]
    after_rollback :clear_emoji_reaction_cache_invalidation_flag
  end

  private

  def mark_emoji_reaction_caches_dirty
    # Reactions still exist here, including during destroy, before the
    # custom_emoji_id ON DELETE CASCADE removes them.
    return unless EmojiReaction.exists?(custom_emoji_id: id)

    EmojiReactionCacheInvalidator.mark_for_custom_emoji_ids(id)
    # INSERT ... ON CONFLICT rowcounts are not a reliable signal that the
    # statement wrote, so the commit callback keys off this flag instead.
    @emoji_reaction_cache_invalidated = true
  end

  def enqueue_dirty_emoji_reaction_cache_refresh
    return unless @emoji_reaction_cache_invalidated

    @emoji_reaction_cache_invalidated = false
    RefreshDirtyEmojiReactionCachesWorker.perform_async
  end

  def clear_emoji_reaction_cache_invalidation_flag
    @emoji_reaction_cache_invalidated = false
  end

  def emoji_reaction_cache_attributes_changing?
    REACTION_CACHE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end
end
