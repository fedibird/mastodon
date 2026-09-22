# frozen_string_literal: true

# The matching material one status presents to Keyword Subscribe.
#
# Three separate channels that are never concatenated:
#
#   body                  legacy Status#searchable_text
#   hashtag_tokens        "#name" for every tag the status carries, including
#                         tags that are not written in the body, plus hashtags
#                         written in the body
#   urls                  Status#filterable_urls
#
# Each URL and each hashtag token is matched on its own, so no keyword and no
# user regexp can span two URLs, two tags, or the seam between the body and a
# URL. Channels are built lazily: a subscription with both options off never
# loads tags and never expands URLs.
class KeywordSubscribe::MatchingContexts
  # Hashtag spans are replaced by a single character that a stored keyword can
  # never contain, because Postgres text cannot hold NUL. A keyword therefore
  # cannot match across a removed hashtag, and a keyword with a space cannot
  # treat a removed hashtag as whitespace.
  HASHTAG_MASK = "\u0000"

  def self.wrap(target)
    case target
    when KeywordSubscribe::MatchingContexts
      target
    when Status
      new(status: target)
    else
      new(body: target.to_s)
    end
  end

  def initialize(status: nil, body: nil)
    @status = status
    @body   = body
  end

  def body
    @body ||= @status ? @status.searchable_text : ''
  end

  # The body with hashtag spans removed. Ordinary keywords reach hashtags
  # through hashtag_tokens, so the body channel carries no hashtag material.
  def body_without_hashtags
    scan_hashtags
    @body_without_hashtags
  end

  def urls
    @urls ||= @status ? @status.filterable_urls : []
  end

  def hashtag_tokens
    @hashtag_tokens ||= (associated_tag_names + written_tag_names).uniq.map { |name| "##{name}" }
  end

  private

  # Every tag associated with the status, including remote tags that the body
  # never spells out. Tag mutes belong to the author, not to the subscriber, so
  # tags_without_mute is deliberately not used here.
  def associated_tag_names
    return [] if @status.nil?

    @status.tags.filter_map(&:name)
  end

  def written_tag_names
    scan_hashtags
    @written_tag_names
  end

  # One pass builds both the masked body and the hashtag names written in it.
  # Tag::HASHTAG_RE consumes the character in front of the tag, so that
  # character is kept and only "#name" is replaced.
  def scan_hashtags
    return if defined?(@body_without_hashtags)

    names = []

    @body_without_hashtags = body.gsub(Tag::HASHTAG_RE) do
      whole = Regexp.last_match(0)
      name  = Regexp.last_match(1)
      names << name
      "#{whole[0, whole.length - name.length - 1]}#{HASHTAG_MASK}"
    end

    @written_tag_names = names
  end
end
