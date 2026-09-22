# frozen_string_literal: true

# Builds the generated pattern for one keyword list in one matching context.
# Raw regexp subscriptions never come through here: their source is used as
# written.
#
# Every context keeps the legacy alternative shape, one alternative per keyword
# joined with `|`:
#
#   (?-mix:(?m[i]x:<start boundary><quoted keyword><end boundary>))
#
# The `(?-mix:...)` wrapper comes from interpolating a Regexp literal into the
# source. It isolates each alternative's flags, so `x` (which makes the quoted
# keyword immune to stray whitespace) and `i` apply per alternative.
#
# Contexts differ in exactly two deliberate ways:
#
#   body      the legacy pattern, byte for byte: a leading `(?<![#])` guard and
#             `/` `.` guards on non-alphanumeric keyword edges.
#   hashtag   the body rules without `(?<![#])`, so `foo` can match the token
#             `#foo` while `foo` still stays out of `#foobar`.
#   url       neither `(?<![#])` nor the `/` `.` guards, because `.` `/` `:`
#             `?` `&` `=` `#` are ordinary URL material rather than a reason to
#             refuse the match. Alphanumeric edges keep their boundary, so
#             `ample` stays out of `https://example.com`.
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

  CONTEXTS = {
    body:    { hashtag_guard: true,  punctuation_guard: true  },
    hashtag: { hashtag_guard: false, punctuation_guard: true  },
    url:     { hashtag_guard: false, punctuation_guard: false },
  }.freeze

  def initialize(ignorecase: true)
    @ignorecase = ignorecase
  end

  def call(keywords, context)
    rules  = CONTEXTS.fetch(context)
    source = keywords.map { |keyword| alternative(keyword, rules) }.join('|')

    Regexp.new("#{rules[:hashtag_guard] ? HASHTAG_START_GUARD : ''}(#{source})", @ignorecase, timeout: MATCH_TIMEOUT)
  end

  private

  def alternative(keyword, rules)
    /(?m#{@ignorecase ? 'i' : ''}x:#{start_boundary(keyword, rules)}#{quoted(keyword)}#{end_boundary(keyword, rules)})/.to_s
  end

  # A space inside one keyword matches a run of whitespace, which is why the
  # alternative runs in `x` mode: the escaped space is replaced rather than
  # silently ignored.
  def quoted(keyword)
    Regexp.quote(keyword).gsub('\ ', '[[:space:]]+')
  end

  def start_boundary(keyword, rules)
    return ALPHANUMERIC_START_GUARD if keyword.match?(ALPHANUMERIC_START)
    return '' unless rules[:punctuation_guard]
    return '' if keyword.match?(PUNCTUATION_START)

    PUNCTUATION_START_GUARD
  end

  def end_boundary(keyword, rules)
    return ALPHANUMERIC_END_GUARD if keyword.match?(ALPHANUMERIC_END)
    return '' unless rules[:punctuation_guard]
    return '' if keyword.match?(PUNCTUATION_END)

    PUNCTUATION_END_GUARD
  end
end
