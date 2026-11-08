# frozen_string_literal: true

# A Unicode mute stores the finished catalog string. U+FE0E and U+FE0F stay
# part of that string. "‼" and "‼️" are different identities even when the
# catalog assigns them one emoji id. Reaction names compare with ==.
class EmojiMutes::UnicodeMatch
  def self.same?(native, reaction_name)
    native.is_a?(String) && reaction_name.is_a?(String) && native == reaction_name
  end

  def self.same_in?(natives, reaction_name)
    reaction_name.is_a?(String) && natives.include?(reaction_name)
  end
end
