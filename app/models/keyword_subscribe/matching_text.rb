# frozen_string_literal: true

# The single string one status presents to Keyword Subscribe.
#
# Both matching modes, generated keywords and user supplied raw regexps, and
# both the positive keyword and exclude_keyword, are evaluated against the same
# prepared string. The two subscription options decide what that string
# contains, and nothing else:
#
#   match_hashtags  false  visible hashtag spans are masked out of the body and
#                          no associated tag is added
#                   true   visible hashtag spans stay in the body and every
#                          associated tag is appended as "#name", including
#                          tags that the body never spells out
#   match_urls      false  nothing is added, so the URL stripped legacy body is
#                          all that is matched
#                   true   Status#filterable_urls is appended, which covers
#                          ordinary URLs, reference canonical URLs, and
#                          ActivityPub URIs
#
# The four combinations are built lazily and memoized per status, so one status
# compared against many subscriptions prepares each string at most once, and a
# subscription with both options off never loads tags and never expands URLs.
class KeywordSubscribe::MatchingText
  # Body parts, synthetic hashtag tokens, and URLs are joined with a single NUL,
  # and masked hashtag spans are replaced by the same character. Postgres text
  # cannot hold NUL, so no stored keyword can contain it: a generated keyword
  # cannot bridge a masked hashtag or the seam between two tags or two URLs, and
  # a keyword written with a space cannot treat a seam as whitespace.
  #
  # A deliberately broad raw regexp can still cross a seam, because the product
  # contract is one prepared string rather than separately matched channels.
  SEPARATOR = "\u0000"

  def self.wrap(target)
    case target
    when KeywordSubscribe::MatchingText
      target
    when Status
      new(status: target)
    else
      new(body: target.to_s)
    end
  end

  def initialize(status: nil, body: nil)
    @status   = status
    @body     = body
    @prepared = {}
  end

  def text_for(match_hashtags:, match_urls:)
    @prepared[[match_hashtags, match_urls]] ||= prepare(match_hashtags, match_urls)
  end

  private

  def prepare(match_hashtags, match_urls)
    parts = [match_hashtags ? body : body_without_hashtags]

    parts.concat(hashtag_tokens) if match_hashtags
    parts.concat(urls)           if match_urls

    parts.join(SEPARATOR)
  end

  # The legacy matching source, which Status already strips of the URLs it
  # discovered.
  def body
    @body ||= @status ? @status.searchable_text : ''
  end

  # Tag::HASHTAG_RE consumes the character in front of the tag, so that
  # character is kept and only "#name" becomes the mask.
  def body_without_hashtags
    @body_without_hashtags ||= body.gsub(Tag::HASHTAG_RE) do
      whole = Regexp.last_match(0)
      name  = Regexp.last_match(1)
      "#{whole[0, whole.length - name.length - 1]}#{SEPARATOR}"
    end
  end

  # Tag mutes belong to the author rather than to the subscriber, so
  # tags_without_mute is deliberately not used here.
  def hashtag_tokens
    @hashtag_tokens ||= @status ? @status.tags.filter_map { |tag| "##{tag.name}" if tag.name.present? } : []
  end

  def urls
    @urls ||= @status ? @status.filterable_urls : []
  end
end
