# frozen_string_literal: true

# Inserts one newline between body text and a trailing hashtag run.
#
# The run is the suffix of Extractor hashtag entities whose gaps, and the
# text after the final hashtag, are whitespace only. A boundary that already
# contains CR or LF is left unchanged, including its surrounding whitespace.
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
    body = prefix.sub(/[[:space:]]+\z/, '')
    return @text if body.empty?

    separator = prefix[body.length..-1]
    return @text if separator.match?(/\r|\n/)

    "#{body}\n#{@text[start..-1]}"
  end

  private

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
