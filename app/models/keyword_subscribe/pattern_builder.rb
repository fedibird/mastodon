# frozen_string_literal: true

# Builds the generated pattern for one keyword list. Raw regexp subscriptions
# never come through here: their source is used exactly as written.
#
# One pattern is matched against one prepared string, and the string is built by
# KeywordSubscribe::MatchingText with the body first and each synthetic segment
# introduced by a marker. That lets the pattern keep different boundaries for
# different regions of the same string, so enabling an option never changes how
# the body is matched:
#
#   body                 the legacy pattern, byte for byte: a leading `(?<![#])`
#                        guard, `/` `.` guards on non-alphanumeric keyword edges,
#                        and alphanumeric edge guards.
#   hashtag segment      the same guards without `(?<![#])`, so `foo` matches the
#                        token `#foo` while `foo` still stays out of `#foobar`.
#   URL segment          alphanumeric edge guards only, because `.` `/` `:` `?`
#                        `&` `=` `#` are ordinary URL material rather than a
#                        reason to refuse the match.
#
# A segment branch starts at its marker and then consumes anything but the
# separator, so it can only match inside one segment of that kind:
#
#   (?<![#])(<body alternatives>)|\x01[^\x00]*?(<hashtag alternatives>)
#
# Each alternative keeps the legacy shape, one per keyword joined with `|`:
#
#   (?-mix:(?m[i]x:<start boundary><quoted keyword><end boundary>))
#
# The `(?-mix:...)` wrapper comes from interpolating a Regexp literal into the
# source. It isolates each alternative's flags, so `x` (which makes the quoted
# keyword immune to stray whitespace) and `i` apply per alternative.
class KeywordSubscribe::PatternBuilder
  ALPHANUMERIC_START = /\A[A-Za-z0-9]/.freeze
  ALPHANUMERIC_END   = /[A-Za-z0-9]\z/.freeze
  PUNCTUATION_START  = %r{\A[/.]}.freeze
  PUNCTUATION_END    = %r{[/.]\z}.freeze

  ALPHANUMERIC_START_GUARD = '(?<![A-Za-z0-9])'
  ALPHANUMERIC_END_GUARD   = '(?![A-Za-z0-9])'
  PUNCTUATION_START_GUARD  = '(?<![\/\.])'
  PUNCTUATION_END_GUARD    = '(?![\/\.])'
  HASHTAG_START_GUARD      = '(?<![#])'

  # Escaped forms of the KeywordSubscribe::MatchingText control characters, kept
  # out of the pattern source as literal bytes so the source stays readable.
  SEPARATOR_PATTERN      = '\x00'
  HASHTAG_MARKER_PATTERN = '\x01'
  URL_MARKER_PATTERN     = '\x02'

  MATCH_TIMEOUT = 2.0

  def initialize(ignorecase: true, match_hashtags: false, match_urls: false)
    @ignorecase     = ignorecase
    @match_hashtags = match_hashtags
    @match_urls     = match_urls
  end

  def call(keywords)
    branches = ["#{HASHTAG_START_GUARD}(#{alternatives(keywords, punctuation_guard: true)})"]

    branches << segment(HASHTAG_MARKER_PATTERN, keywords, punctuation_guard: true) if @match_hashtags
    branches << segment(URL_MARKER_PATTERN, keywords, punctuation_guard: false)    if @match_urls

    Regexp.new(branches.join('|'), @ignorecase, timeout: MATCH_TIMEOUT)
  end

  private

  def segment(marker, keywords, punctuation_guard:)
    "#{marker}[^#{SEPARATOR_PATTERN}]*?(#{alternatives(keywords, punctuation_guard: punctuation_guard)})"
  end

  def alternatives(keywords, punctuation_guard:)
    keywords.map { |keyword| alternative(keyword, punctuation_guard) }.join('|')
  end

  def alternative(keyword, punctuation_guard)
    /(?m#{@ignorecase ? 'i' : ''}x:#{start_boundary(keyword, punctuation_guard)}#{quoted(keyword)}#{end_boundary(keyword, punctuation_guard)})/.to_s
  end

  # A space inside one keyword matches a run of whitespace, which is why the
  # alternative runs in `x` mode: the escaped space is replaced rather than
  # silently ignored.
  def quoted(keyword)
    Regexp.quote(keyword).gsub('\ ', '[[:space:]]+')
  end

  def start_boundary(keyword, punctuation_guard)
    return ALPHANUMERIC_START_GUARD if keyword.match?(ALPHANUMERIC_START)
    return '' unless punctuation_guard
    return '' if keyword.match?(PUNCTUATION_START)

    PUNCTUATION_START_GUARD
  end

  def end_boundary(keyword, punctuation_guard)
    return ALPHANUMERIC_END_GUARD if keyword.match?(ALPHANUMERIC_END)
    return '' unless punctuation_guard
    return '' if keyword.match?(PUNCTUATION_END)

    PUNCTUATION_END_GUARD
  end
end
