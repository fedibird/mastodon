# frozen_string_literal: true

# A context target is missing or not visible to this user. The response
# stays indistinguishable from an unknown id.
class EmojiReferences::NotFound < StandardError
end
