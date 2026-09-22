# frozen_string_literal: true

# The single string one status presents to Keyword Subscribe.
#
# Both matching modes, generated keywords and user supplied raw regexps, and
# both the positive keyword and exclude_keyword, are evaluated against the same
# prepared string. The two subscription options decide what that string
# contains, and nothing else:
#
#   match_hashtags  false  visible hashtag spans are masked out of the body and
#                          no tag is appended
#                   true   visible hashtag spans stay in the body and every tag
#                          the status carries is appended as "#name", including
#                          tags that the body never spells out
#   match_urls      false  no URL material at all
#                   true   Status#filterable_urls is appended, which covers
#                          ordinary URLs, reference canonical URLs, and
#                          ActivityPub URIs, each in its canonical form and in
#                          the human-readable form Formatter shows as link text
#
# URL spans written in the body are masked whichever way match_urls is set.
# Status#searchable_text only removes the URLs that Status itself discovered, so
# a URL whose normalized form differs from the written one survives there: the
# body of https://example.com/東京/page keeps the written form while
# Status#filterable_urls reports the percent-encoded one. Masking the body keeps
# the option honest, and it also means URL material only ever reaches the matcher
# through Status#filterable_urls, one segment per representation.
#
# The four combinations are built lazily and memoized per status, so one status
# compared against many subscriptions prepares each string at most once, and a
# subscription with both options off never loads tags and never expands URLs.
class KeywordSubscribe::MatchingText
  # Segments are joined with a single NUL. Postgres text cannot hold NUL, so no
  # stored keyword can contain it: a generated keyword cannot bridge a masked
  # span or the seam between two tags or two URLs, and a keyword written with a
  # space cannot treat a seam as whitespace.
  SEPARATOR = "\u0000"

  # Each synthetic segment starts with a marker right after the separator, which
  # is what lets one generated pattern apply body boundaries to the body and
  # hashtag or URL boundaries inside the segments of that kind. See
  # KeywordSubscribe::PatternBuilder.
  HASHTAG_MARKER = "\u0001"
  URL_MARKER     = "\u0002"

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
    @status        = status
    @body          = body
    @prepared      = {}
    @body_material = {}
  end

  def text_for(match_hashtags:, match_urls:)
    @prepared[[match_hashtags, match_urls]] ||= prepare(match_hashtags, match_urls)
  end

  private

  def prepare(match_hashtags, match_urls)
    parts = [body_material(match_hashtags)]

    parts.concat(hashtag_tokens.map { |token| "#{HASHTAG_MARKER}#{token}" }) if match_hashtags
    parts.concat(urls.map { |url| "#{URL_MARKER}#{url}" })                   if match_urls

    parts.join(SEPARATOR)
  end

  # The legacy matching source with its URL spans masked, and with its hashtag
  # spans masked as well while match_hashtags is off.
  def body_material(keep_hashtags)
    @body_material[keep_hashtags] ||= mask(body, keep_hashtags)
  end

  def body
    @body ||= @status ? @status.searchable_text : ''
  end

  def mask(text, keep_hashtags)
    entities = url_entities(text)
    entities += Extractor.extract_hashtags_with_indices(text) unless keep_hashtags
    spans = Extractor.remove_overlapping_entities(entities).map { |entity| entity[:indices] }

    return text if spans.empty?

    masked = +''
    last   = 0

    spans.each do |(start, finish)|
      masked << text[last...start] << SEPARATOR
      last = finish
    end

    masked << text[last..-1]
  end

  # The same extraction Formatter uses when it linkifies a body, rather than a
  # second URL parser of our own. Protocol-less text such as a bare `example.com`
  # is not a URL to Mastodon, so it stays ordinary body material here too.
  def url_entities(text)
    Extractor.extract_urls_with_indices(text, extract_url_without_protocol: false) +
      Extractor.extract_extra_uris_with_indices(text)
  end

  # Tags the status carries plus the hashtags written in the body, so a visible
  # hashtag is matchable even when no Tag record was associated. Tag mutes belong
  # to the author rather than to the subscriber, so tags_without_mute is
  # deliberately not used here.
  def hashtag_tokens
    @hashtag_tokens ||= (associated_tag_names + written_tag_names).uniq.map { |name| "##{name}" }
  end

  def associated_tag_names
    return [] if @status.nil?

    @status.tags.filter_map { |tag| tag.name.presence }
  end

  def written_tag_names
    Extractor.extract_hashtags_with_indices(body).map { |entity| entity[:hashtag] }
  end

  def urls
    @urls ||= @status ? @status.filterable_urls : []
  end
end
