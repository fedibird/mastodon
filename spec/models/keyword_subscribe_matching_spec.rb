# frozen_string_literal: true

require 'rails_helper'

# The matching matrix for the two new options.
#
# Both matching modes read one prepared string per status and option pair, built
# by KeywordSubscribe::MatchingText:
#
#   base           legacy Status#searchable_text, which Status already strips of
#                  the URLs it discovered
#   match_hashtags off masks visible hashtag spans, on keeps them and appends one
#                  "#name" token per tag the status carries
#   match_urls     off adds nothing, on appends Status#filterable_urls
#
# Parts are joined with a single NUL, which no stored keyword can contain.
RSpec.describe KeywordSubscribe, '#match? with a status' do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account, username: 'subscriber') }
  let(:author)  { Fabricate(:account, domain: nil, username: 'author') }

  # keyword= and exclude_keyword= normalize based on the regexp flag, so the flag
  # is assigned before them.
  def subscribe(keyword, **options)
    attributes = { account: account, regexp: false, ignorecase: true, match_hashtags: false, match_urls: false, exclude_keyword: '' }.merge(options)

    described_class.new(attributes.merge(keyword: keyword))
  end

  def status_with(text, tags: [])
    status = Fabricate(:status, account: author, text: text)
    tags.each { |name| status.tags << Fabricate(:tag, name: name) }
    status
  end

  def referencing_status(target)
    status = Fabricate(:status, account: author, text: 'see the other post')
    Fabricate(:status_reference, status: status, target_status: target)
    status
  end

  describe 'with both options off' do
    it 'matches ordinary body text' do
      status = status_with('a bodyword here')

      expect(subscribe('bodyword').match?(status)).to be true
      expect(subscribe('otherword').match?(status)).to be false
    end

    it 'does not match a URL that only appears as a link' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('example.com').match?(status)).to be false
      expect(subscribe('pathword').match?(status)).to be false
      expect(subscribe('https://example.com/pathword').match?(status)).to be false
      expect(subscribe('look').match?(status)).to be true
    end

    it 'does not match a referenced status URL or ActivityPub URI' do
      target = status_with('the original')
      status = referencing_status(target)

      expect(subscribe(ActivityPub::TagManager.instance.url_for(target)).match?(status)).to be false
      expect(subscribe(ActivityPub::TagManager.instance.uri_for(target)).match?(status)).to be false
    end

    it 'does not match a tag that is only associated with the status' do
      status = status_with('no tag in this text', tags: %w(fediverse))

      expect(subscribe('fediverse').match?(status)).to be false
      expect(subscribe('#fediverse').match?(status)).to be false
    end

    it 'does not match anywhere inside a visible hashtag' do
      status = status_with('hello #foo_bar and #東京都', tags: %w(foo_bar 東京都))

      expect(subscribe('foo').match?(status)).to be false
      expect(subscribe('bar').match?(status)).to be false
      expect(subscribe('foo_bar').match?(status)).to be false
      expect(subscribe('#foo_bar').match?(status)).to be false
      expect(subscribe('東京').match?(status)).to be false
      expect(subscribe('hello').match?(status)).to be true
    end

    it 'follows ignorecase' do
      status = status_with('a BODYWORD here')

      expect(subscribe('bodyword').match?(status)).to be true
      expect(subscribe('bodyword', ignorecase: false).match?(status)).to be false
    end

    # Revised in this change: a raw regexp reads the same prepared string as a
    # generated keyword, so it sees neither hashtag nor URL material here.
    it 'gives a raw regexp the same body only string' do
      status = status_with('regexpbody https://example.com/pathword #fediverse', tags: %w(fediverse))

      expect(subscribe('regexpb.dy', regexp: true).match?(status)).to be true
      expect(subscribe('pathword', regexp: true).match?(status)).to be false
      expect(subscribe('example\.com', regexp: true).match?(status)).to be false
      expect(subscribe('#fediverse', regexp: true).match?(status)).to be false
      expect(subscribe('fedi\w+', regexp: true).match?(status)).to be false
    end
  end

  describe 'with match_urls only' do
    it 'matches a domain, a path component, and the full URL' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('example', match_urls: true).match?(status)).to be true
      expect(subscribe('example.com', match_urls: true).match?(status)).to be true
      expect(subscribe('pathword', match_urls: true).match?(status)).to be true
      expect(subscribe('https://example.com/pathword', match_urls: true).match?(status)).to be true
    end

    it 'matches a remote HTML anchor URL' do
      remote = Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/@bob')
      status = Fabricate(:status, account: remote, text: '<p>hi <a href="https://example.com/pathword">example.com/pathword</a></p>')

      expect(subscribe('pathword', match_urls: true).match?(status)).to be true
    end

    it 'matches a referenced status canonical URL and ActivityPub URI' do
      target = status_with('the original')
      status = referencing_status(target)

      expect(subscribe(ActivityPub::TagManager.instance.url_for(target), match_urls: true).match?(status)).to be true
      expect(subscribe(ActivityPub::TagManager.instance.uri_for(target), match_urls: true).match?(status)).to be true
    end

    it 'keeps ASCII token protection inside a URL' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('ample', match_urls: true).match?(status)).to be false
      expect(subscribe('athword', match_urls: true).match?(status)).to be false
    end

    it 'matches a keyword whose edge is punctuation next to a slash' do
      status = status_with('look https://example.com/c++/page')

      expect(subscribe('c++', match_urls: true).match?(status)).to be true
      expect(subscribe('c++').match?('c++/page')).to be false
    end

    it 'lets a raw regexp match URL material without rewriting the source' do
      status = status_with('look https://example.com/pathword')
      subscription = subscribe('example\.com/path\w+', regexp: true, match_urls: true)

      expect(subscription.keyword).to eq 'example\.com/path\w+'
      expect(subscription.keyword_regexp.source).to eq 'example\.com/path\w+'
      expect(subscription.match?(status)).to be true
    end
  end

  # Enabling match_urls adds URL material, and nothing else: the body keeps the
  # legacy keyword boundaries whichever way the option is set.
  describe 'body boundaries are independent of match_urls' do
    def body_results(keyword, text)
      status = status_with(text)

      [[false, false], [true, false], [false, true], [true, true]].map do |match_hashtags, match_urls|
        subscribe(keyword, match_hashtags: match_hashtags, match_urls: match_urls).match?(status)
      end
    end

    it 'keeps the slash and dot guards on body text' do
      expect(body_results('東京', 'まとめ/東京の話')).to eq [false, false, false, false]
    end

    it 'keeps the legacy dot boundary of a punctuation-edged keyword' do
      expect(body_results('foo.', 'a foo.bar here')).to eq [true, true, true, true]
      expect(body_results('c++', 'a c++/page here')).to eq [false, false, false, false]
    end

    it 'keeps the legacy boundary of a hash that is not a hashtag' do
      expect(body_results('1', 'issue #1 here')).to eq [false, false, false, false]
    end

    it 'keeps ordinary alphanumeric body matching' do
      expect(body_results('bar', 'a foo.bar here')).to eq [true, true, true, true]
      expect(body_results('bodyword', 'a bodyword here')).to eq [true, true, true, true]
    end
  end

  # Status#searchable_text only removes the URLs Status itself discovered, so a
  # URL whose normalized form differs from the written one survives in the body.
  # KeywordSubscribe::MatchingText masks URL spans out of the body either way, so
  # match_urls off means no URL bytes at all, and match_urls on means the
  # normalized Status#filterable_urls material and nothing else.
  describe 'URL material is masked out of the body' do
    let(:status) { status_with('look https://example.com/東京/page') }

    it 'leaves the written URL in Status#searchable_text' do
      expect(status.searchable_text).to include 'https://example.com/東京/page'
      expect(status.filterable_urls).to eq ['https://example.com/%E6%9D%B1%E4%BA%AC/page']
    end

    it 'hides the written URL from a raw regexp while match_urls is off' do
      expect(subscribe('東京', regexp: true).match?(status)).to be false
      expect(subscribe('example\.com', regexp: true).match?(status)).to be false
      expect(subscribe('https://example\.com/\S+', regexp: true).match?(status)).to be false
    end

    it 'hides the written URL from a generated keyword while match_urls is off' do
      expect(subscribe('example.com').match?(status)).to be false
      expect(subscribe('https://example.com/東京/page').match?(status)).to be false
    end

    it 'adds only the normalized URL material with match_urls on' do
      expect(subscribe('example.com', match_urls: true).match?(status)).to be true
      expect(subscribe('%E6%9D%B1%E4%BA%AC', match_urls: true).match?(status)).to be true
      expect(subscribe('example\.com/%E6%9D%B1%E4%BA%AC', regexp: true, match_urls: true).match?(status)).to be true
    end

    # The percent-encoded form is all the matcher receives, so a Japanese keyword
    # still does not reach a Japanese URL path. A follow-up will add a decoded
    # matching representation; this pins today's behavior.
    it 'does not match a Japanese keyword against a percent-encoded path' do
      expect(subscribe('東京', match_urls: true).match?(status)).to be false
      expect(subscribe('東京', regexp: true, match_urls: true).match?(status)).to be false
    end
  end

  describe 'with match_urls only, outside URL material' do
    # A fragment is URL material, so it stays matchable even though visible body
    # hashtags are masked out by match_hashtags being off.
    it 'matches a URL fragment while body hashtags stay masked' do
      status = status_with('see https://example.com/#foo now #foo', tags: %w(foo))

      expect(status.filterable_urls).to eq ['https://example.com/#foo']
      expect(subscribe('foo', match_urls: true).match?(status)).to be true
      expect(subscribe('#foo', match_urls: true).match?(status)).to be true
    end

    it 'does not match a body hashtag whose name is absent from URL material' do
      status = status_with('hello #fediverse https://example.com/pathword', tags: %w(fediverse))

      expect(subscribe('fediverse', match_urls: true).match?(status)).to be false
      expect(subscribe('pathword', match_urls: true).match?(status)).to be true
    end

    it 'does not match an associated tag' do
      status = status_with('no tag in this text', tags: %w(fediverse))

      expect(subscribe('fediverse', match_urls: true).match?(status)).to be false
    end
  end

  describe 'with match_hashtags only' do
    it 'matches a visible hashtag' do
      status = status_with('hello #fediverse', tags: %w(fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
      expect(subscribe('#fediverse', match_hashtags: true).match?(status)).to be true
    end

    it 'matches a tag that is not written in the body' do
      status = status_with('no tag in this text', tags: %w(fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
      expect(subscribe('#fediverse', match_hashtags: true).match?(status)).to be true
    end

    it 'does not match a URL' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('pathword', match_hashtags: true).match?(status)).to be false
      expect(subscribe('example.com', match_hashtags: true).match?(status)).to be false
    end

    it 'lets a raw regexp match a visible hashtag and a hidden tag token' do
      visible = status_with('hello #fediverse', tags: [])
      hidden  = status_with('no tag in this text', tags: %w(fediverse))
      source  = '#fedi\w+'

      expect(subscribe(source, regexp: true, match_hashtags: true).match?(visible)).to be true
      expect(subscribe(source, regexp: true, match_hashtags: true).match?(hidden)).to be true
      expect(subscribe(source, regexp: true).match?(visible)).to be false
      expect(subscribe(source, regexp: true).match?(hidden)).to be false
    end
  end

  describe 'with match_hashtags only, keyword boundaries' do
    it 'keeps the ASCII end boundary inside a tag' do
      status = status_with('no tag in this text', tags: %w(foobar))

      expect(subscribe('foo', match_hashtags: true).match?(status)).to be false
      expect(subscribe('foobar', match_hashtags: true).match?(status)).to be true
    end

    it 'matches across an underscore separator inside a tag, like body text' do
      status = status_with('no tag in this text', tags: %w(foo_bar))

      expect(subscribe('foo', match_hashtags: true).match?(status)).to be true
      expect(subscribe('bar', match_hashtags: true).match?(status)).to be true
    end

    it 'matches a Japanese tag as a substring, like body keywords' do
      status = status_with('no tag in this text', tags: %w(東京都))

      expect(subscribe('東京', match_hashtags: true).match?(status)).to be true
      expect(subscribe('京', match_hashtags: true).match?(status)).to be true
      expect(subscribe('大阪', match_hashtags: true).match?(status)).to be false
    end

    it 'follows ignorecase on hashtag material' do
      status = status_with('no tag in this text', tags: %w(Fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
      expect(subscribe('fediverse', match_hashtags: true, ignorecase: false).match?(status)).to be false
      expect(subscribe('Fediverse', match_hashtags: true, ignorecase: false).match?(status)).to be true
    end

    it 'does not treat a URL fragment as a hashtag of the status' do
      status = status_with('see https://example.com/#foo now')

      expect(status.filterable_urls).to eq ['https://example.com/#foo']
      expect(subscribe('foo', match_hashtags: true).match?(status)).to be false
      expect(subscribe('#foo', match_hashtags: true).match?(status)).to be false
      expect(subscribe('foo', match_hashtags: true, match_urls: true).match?(status)).to be true
    end

    it 'matches a URL fragment name when the status really carries that tag' do
      status = status_with('see https://example.com/#foo now', tags: %w(foo))

      expect(subscribe('foo', match_hashtags: true).match?(status)).to be true
    end
  end

  describe 'with both options on' do
    it 'matches by body, by URL, or by hashtag' do
      status = status_with('bodyword https://example.com/pathword', tags: %w(fediverse))

      expect(subscribe('bodyword', match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('pathword', match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('fediverse', match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('otherword', match_hashtags: true, match_urls: true).match?(status)).to be false
    end

    it 'does not let a generated keyword bridge two URLs' do
      first = status_with('the first')
      second = status_with('the second')
      status = Fabricate(:status, account: author, text: "see #{ActivityPub::TagManager.instance.url_for(first)} and #{ActivityPub::TagManager.instance.url_for(second)}")
      Fabricate(:status_reference, status: status, target_status: first)
      Fabricate(:status_reference, status: status, target_status: second)

      expect(status.filterable_urls.size).to be > 1
      expect(subscribe("#{first.id} #{second.id}", match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe(first.id.to_s, match_hashtags: true, match_urls: true).match?(status)).to be true
    end

    it 'does not let a generated keyword bridge two tags' do
      status = status_with('no tag in this text', tags: %w(alpha beta))

      expect(subscribe('alpha beta', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('#alpha #beta', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('alpha', match_hashtags: true, match_urls: true).match?(status)).to be true
    end

    it 'does not let a generated keyword bridge the body and a URL' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyword https', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('bodyword pathword', match_hashtags: true, match_urls: true).match?(status)).to be false
    end

    it 'does not let a generated keyword bridge a masked hashtag' do
      status = status_with('foo #tag bar')

      expect(subscribe('foo bar').match?(status)).to be false
      expect(subscribe('foo bar', match_urls: true).match?(status)).to be false
    end

    # Accepted consequence of the one prepared string contract: a deliberately
    # broad raw regexp that matches any byte can cross a seam. Generated keywords
    # cannot, which is what the examples above pin down.
    it 'lets a deliberately broad raw regexp cross the seams' do
      status = status_with('bodyword https://example.com/pathword', tags: %w(fediverse))

      expect(subscribe('bodyword[\s\S]*pathword', regexp: true, match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('bodyword pathword', regexp: true, match_hashtags: true, match_urls: true).match?(status)).to be false
    end
  end

  describe 'exclude_keyword' do
    it 'reads the same prepared string as the positive keyword' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyword', exclude_keyword: 'pathword', match_urls: true).match?(status)).to be false
      expect(subscribe('bodyword', exclude_keyword: 'pathword').match?(status)).to be true
    end

    it 'excludes on hashtag material only when match_hashtags is on' do
      status = status_with('bodyword here', tags: %w(spoiledtag))

      expect(subscribe('bodyword', exclude_keyword: 'spoiledtag', match_hashtags: true).match?(status)).to be false
      expect(subscribe('bodyword', exclude_keyword: 'spoiledtag').match?(status)).to be true
    end

    it 'excludes a hashtag match through a body keyword' do
      status = status_with('bodyword here', tags: %w(fediverse))

      expect(subscribe('fediverse', exclude_keyword: 'bodyword', match_hashtags: true).match?(status)).to be false
    end

    it 'uses the same prepared string in raw regexp mode' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyw.rd', exclude_keyword: 'path\w+', regexp: true, match_urls: true).match?(status)).to be false
      expect(subscribe('bodyw.rd', exclude_keyword: 'path\w+', regexp: true).match?(status)).to be true
    end
  end

  describe 'multiple comma keywords' do
    it 'lets separate alternatives match separate material' do
      status = status_with('plain body https://example.com/pathword', tags: %w(fediverse))
      keywords = 'bodyword,pathword,fediverse'

      expect(subscribe(keywords, match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('pathword,nothinghere', match_urls: true).match?(status)).to be true
      expect(subscribe('fediverse,nothinghere', match_hashtags: true).match?(status)).to be true
      expect(subscribe('nothinghere,stillnothing', match_hashtags: true, match_urls: true).match?(status)).to be false
    end

    it 'keeps each alternative boundary in URL material' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('ample,athword', match_urls: true).match?(status)).to be false
      expect(subscribe('ample,pathword', match_urls: true).match?(status)).to be true
    end
  end

  describe 'generated pattern sources' do
    it 'builds the default combination exactly as the legacy pattern did' do
      legacy = '(?<![#])((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:(?<![\/\.])東京(?![\/\.])))'

      expect(subscribe('foo,東京').keyword_regexp.source).to eq legacy
    end

    it 'keeps the legacy body branch and adds a hashtag segment branch with match_hashtags' do
      body    = '(?<![#])((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:(?<![\/\.])東京(?![\/\.])))'
      segment = '\\x01[^\\x00]*?((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:(?<![\/\.])東京(?![\/\.])))'

      expect(subscribe('foo,東京', match_hashtags: true).keyword_regexp.source).to eq "#{body}|#{segment}"
    end

    it 'keeps the legacy body branch and adds a URL segment branch without punctuation guards with match_urls' do
      body    = '(?<![#])((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:(?<![\/\.])東京(?![\/\.])))'
      segment = '\\x02[^\\x00]*?((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:東京))'

      expect(subscribe('foo,東京', match_urls: true).keyword_regexp.source).to eq "#{body}|#{segment}"
    end

    it 'names the segment markers that KeywordSubscribe::MatchingText writes' do
      separator = Regexp.new(KeywordSubscribe::PatternBuilder::SEPARATOR_PATTERN)
      hashtag   = Regexp.new(KeywordSubscribe::PatternBuilder::HASHTAG_MARKER_PATTERN)
      url       = Regexp.new(KeywordSubscribe::PatternBuilder::URL_MARKER_PATTERN)

      expect(separator.match?(KeywordSubscribe::MatchingText::SEPARATOR)).to be true
      expect(hashtag.match?(KeywordSubscribe::MatchingText::HASHTAG_MARKER)).to be true
      expect(url.match?(KeywordSubscribe::MatchingText::URL_MARKER)).to be true
    end

    it 'keeps the match timeout in every combination' do
      [[false, false], [true, false], [false, true], [true, true]].each do |match_hashtags, match_urls|
        subscription = subscribe('foo', exclude_keyword: 'bar', match_hashtags: match_hashtags, match_urls: match_urls)

        expect(subscription.keyword_regexp.timeout).to eq 2.0
        expect(subscription.exclude_keyword_regexp.timeout).to eq 2.0
      end
    end

    it 'keeps a raw regexp source byte for byte in every combination' do
      source = '^\s*#fo+o\s*(bar|baz)\z'

      [[false, false], [true, false], [false, true], [true, true]].each do |match_hashtags, match_urls|
        subscription = subscribe(source, regexp: true, match_hashtags: match_hashtags, match_urls: match_urls)

        expect(subscription.keyword).to eq source
        expect(subscription.keyword_regexp.source).to eq source
        expect(subscription.keyword_regexp.timeout).to eq 2.0
      end
    end
  end
end
