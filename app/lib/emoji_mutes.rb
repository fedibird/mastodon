# frozen_string_literal: true

# Owner-scoped emoji mute rules. The capability token `emoji_mutes` stays
# unpublished until text replacement and picker exclusion are enforced too.
module EmojiMutes
  CACHE_VERSION = 2
  MAX_PER_ACCOUNT = 500
  MAX_REPLACEMENT_CHARS = 32
  MAX_REPLACEMENT_BYTES = 128
  MAX_BODY_BYTES = 8 * 1024
  DEFAULT_REPLACEMENT = '［絵文字］'
  LEGACY_STATUS_LIMIT = 40
  LEGACY_ROW_LIMIT = 2_000
  EFFECTS = %w(
    replace_in_text
    reject_reactions_to_own_posts
    hide_reactions
    hide_in_picker
  ).freeze
end
