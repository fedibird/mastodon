# frozen_string_literal: true

module EmojiMutes
  # A mute stores one finished catalog native. Ruby, SQL, and the WebUI
  # compare that string exactly. Variation selectors, skin tone, ZWJ, flags,
  # and keycaps stay distinct, including pairs that share a catalog id
  # (‼ and ‼️) and pairs that do not (1⃣ and 1️⃣).
  module UnicodeMatch
    module_function

    def match?(stored_native, reaction_name)
      stored_native.is_a?(String) && reaction_name.is_a?(String) && stored_native == reaction_name
    end

    def variants(native)
      native.is_a?(String) ? [native] : []
    end
  end
end
