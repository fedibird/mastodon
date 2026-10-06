# frozen_string_literal: true

# Guarantees one blank line between body text and a trailing hashtag run.
#
# The run is the suffix of Extractor hashtag entities whose gaps, and the
# text after the final hashtag, are whitespace only. Tag-only posts and
# hashtags that are not at the end stay unchanged. Zero logical newlines
# become two, and a single logical newline gains one more. A boundary that
# already has two or more logical newlines is left untouched, including
# extra blank lines. Horizontal whitespace at the end of the body may be
# removed when a newline is inserted.
#
# Local compose, edit, and scheduled publish call this. Remote ActivityPub
# create and update must not.
class TrailingHashtagNormalizer
  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    run = trailing_run
    return @text if run.empty?

    start = run.first[:indices].first
    return @text if start.zero?

    prefix = @text[0...start]
    body, separator = split_trailing_whitespace(prefix)
    return @text if body.empty?

    breaks = separator.scan(/\r\n|\r|\n/)
    return @text if breaks.size >= 2

    gap = breaks.empty? ? "\n\n" : "#{breaks.join}\n"
    "#{body}#{gap}#{@text[start..-1]}"
  end

  private

  def split_trailing_whitespace(prefix)
    match = prefix.match(/[[:space:]]+\z/)
    return [prefix, ''] unless match

    [prefix[0, match.begin(0)], match[0]]
  end

  def trailing_run
    entities = Extractor.extract_hashtags_with_indices(@text)
    run = []

    entities.reverse_each do |entity|
      break unless gap_after(entity, run).match?(/\A[[:space:]]*\z/)

      run.unshift(entity)
    end

    run
  end

  def gap_after(entity, run)
    finish = entity[:indices].last
    return @text[finish..-1].to_s if run.empty?

    @text[finish...run.first[:indices].first].to_s
  end
end
