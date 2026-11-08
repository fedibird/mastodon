# frozen_string_literal: true

module EmojiMutes
  # Mute rows keep the finished catalog native. Reaction rows keep whatever
  # string passed EmojiReactionValidator (an emoji_map key). Those strings
  # sometimes differ only by variation selectors U+FE0E and U+FE0F.
  #
  # A stored native matches a reaction name when they are equal, or when
  # both strings are equal after those selectors are removed, unless both
  # are distinct catalog entries. Skin tone, ZWJ, flags, and keycaps stay
  # in the stripped string, so they do not collapse into the base emoji.
  module UnicodeMatch
    VS = /[\uFE0E\uFE0F]/.freeze

    module_function

    def match?(stored_native, reaction_name)
      return false if !stored_native.is_a?(String) || !reaction_name.is_a?(String)
      return true if stored_native == reaction_name

      left = stored_native.gsub(VS, '')
      right = reaction_name.gsub(VS, '')
      return false if left.empty? || left != right

      stored = PersonalEmojiSets::UnicodeCatalog.find(stored_native)
      other = PersonalEmojiSets::UnicodeCatalog.find(reaction_name)
      return false if stored && other && stored[:id] != other[:id]

      true
    end

    def variants(native)
      return [] unless native.is_a?(String)

      [native, native.gsub(VS, '')].uniq
    end
  end
end
