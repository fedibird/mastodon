# frozen_string_literal: true

# Builds the generated pattern for one keyword list. Raw regexp subscriptions
# never come through here: their source is used exactly as written.
#
# The generated pattern keeps the legacy alternative shape, one alternative per
# keyword joined with `|`:
#
#   (?-mix:(?m[i]x:<start boundary><quoted keyword><end boundary>))
#
# The `(?-mix:...)` wrapper comes from interpolating a Regexp literal into the
# source. It isolates each alternative's flags, so `x` (which makes the quoted
# keyword immune to stray whitespace) and `i` apply per alternative.
#
# Two guards are switched by the subscription options, because the prepared
# string they are matched against changes with those options:
#
#   hashtag_guard      the legacy `(?<![#])`, kept while both options are off.
#                      Hashtag spans are already masked out of the prepared
#                      string then, so the guard only still covers a `#` that is
#                      not a hashtag, such as `#1`. Dropping it is what lets
#                      `foo` match the token `#foo` with match_hashtags on and
#                      the fragment of https://example.com/#foo with match_urls
#                      on, while the alphanumeric guards still keep `foo` out of
#                      `#foobar`.
#   punctuation_guard  the legacy `/` `.` guards on non-alphanumeric keyword
#                      edges, kept while match_urls is off. With match_urls on,
#                      `.` `/` `:` `?` `&` `=` `#` are ordinary URL material
#                      rather than a reason to refuse the match, so the guards
#                      are dropped for the whole prepared string.
#
# Alphanumeric edge guards are never switched, so `ample` stays out of
# `https://example.com/path` and `athword` stays out of `/pathword`.
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

  MATCH_TIMEOUT = 2.0

  def initialize(ignorecase: true, hashtag_guard: true, punctuation_guard: true)
    @ignorecase        = ignorecase
    @hashtag_guard     = hashtag_guard
    @punctuation_guard = punctuation_guard
  end

  def call(keywords)
    source = keywords.map { |keyword| alternative(keyword) }.join('|')

    Regexp.new("#{@hashtag_guard ? HASHTAG_START_GUARD : ''}(#{source})", @ignorecase, timeout: MATCH_TIMEOUT)
  end

  private

  def alternative(keyword)
    /(?m#{@ignorecase ? 'i' : ''}x:#{start_boundary(keyword)}#{quoted(keyword)}#{end_boundary(keyword)})/.to_s
  end

  # A space inside one keyword matches a run of whitespace, which is why the
  # alternative runs in `x` mode: the escaped space is replaced rather than
  # silently ignored.
  def quoted(keyword)
    Regexp.quote(keyword).gsub('\ ', '[[:space:]]+')
  end

  def start_boundary(keyword)
    return ALPHANUMERIC_START_GUARD if keyword.match?(ALPHANUMERIC_START)
    return '' unless @punctuation_guard
    return '' if keyword.match?(PUNCTUATION_START)

    PUNCTUATION_START_GUARD
  end

  def end_boundary(keyword)
    return ALPHANUMERIC_END_GUARD if keyword.match?(ALPHANUMERIC_END)
    return '' unless @punctuation_guard
    return '' if keyword.match?(PUNCTUATION_END)

    PUNCTUATION_END_GUARD
  end
end
