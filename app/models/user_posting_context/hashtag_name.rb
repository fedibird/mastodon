# frozen_string_literal: true

class UserPostingContext
  # Matches the Composer managed-hashtag comparison: strip a leading hash,
  # drop trailing separators, then NFKC and case-fold. The visible spelling
  # stays in `name`; `normalized_name` is only for equality.
  class HashtagName
    LEADING_HASH = /\A[#＃]+/.freeze
    TRAILING_SEPARATOR = /[·・\u200C]+\z/.freeze
    MAX_LENGTH = 100

    def self.canonicalize(raw)
      display = raw.to_s.strip.gsub(LEADING_HASH, '').gsub(TRAILING_SEPARATOR, '').strip
      return if display.blank? || display.length > MAX_LENGTH
      return unless display.match?(Tag::HASHTAG_NAME_RE)

      [display, display.unicode_normalize(:nfkc).downcase]
    end
  end
end
