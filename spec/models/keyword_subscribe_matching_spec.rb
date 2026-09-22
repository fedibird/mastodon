# frozen_string_literal: true

require 'rails_helper'

# The matching matrix for the two new options. The body channel is always
# legacy Status#searchable_text; match_urls adds Status#filterable_urls and
# match_hashtags adds one token per tag the status carries.
RSpec.describe KeywordSubscribe, '#match? with a status' do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account, username: 'subscriber') }
  let(:author)  { Fabricate(:account, domain: nil, username: 'author') }

  def subscribe(keyword, exclude_keyword: '', ignorecase: true, regexp: false, match_hashtags: false, match_urls: false)
    described_class.new(
      account: account,
      regexp: regexp,
      ignorecase: ignorecase,
      match_hashtags: match_hashtags,
      match_urls: match_urls,
      keyword: keyword,
      exclude_keyword: exclude_keyword
    )
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
      expect(subscribe('東京').match?(status)).to be false
      expect(subscribe('hello').match?(status)).to be true
    end

    it 'follows ignorecase on the body channel' do
      status = status_with('a BODYWORD here')

      expect(subscribe('bodyword').match?(status)).to be true
      expect(subscribe('bodyword', ignorecase: false).match?(status)).to be false
    end

    it 'keeps raw regexp body behavior and adds no channel' do
      status = status_with('regexpbody https://example.com/pathword', tags: %w(fediverse))

      expect(subscribe('regexpb.dy', regexp: true).match?(status)).to be true
      expect(subscribe('pathword', regexp: true).match?(status)).to be false
      expect(subscribe('fediverse', regexp: true).match?(status)).to be false
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
      # Body text still refuses the same adjacency, where `/` stays a boundary.
      expect(subscribe('c++').match?('c++/page')).to be false
    end

    # Status#filterable_urls normalizes URLs, so a non-ASCII path arrives
    # percent-encoded. The URL channel matches what the status actually carries.
    it 'sees a non-ASCII URL path in its percent-encoded form' do
      status = status_with('look https://example.com/東京/page')

      expect(status.filterable_urls).to eq ['https://example.com/%E6%9D%B1%E4%BA%AC/page']
      expect(subscribe('東京', match_urls: true).match?(status)).to be false
      expect(subscribe('%E6%9D%B1%E4%BA%AC', match_urls: true).match?(status)).to be true
    end

    it 'does not match an associated tag' do
      status = status_with('no tag in this text', tags: %w(fediverse))

      expect(subscribe('fediverse', match_urls: true).match?(status)).to be false
    end

    it 'lets a raw regexp match the URL channel without rewriting the source' do
      status = status_with('look https://example.com/pathword')
      subscription = subscribe('example\.com/path\w+', regexp: true, match_urls: true)

      expect(subscription.keyword).to eq 'example\.com/path\w+'
      expect(subscription.keyword_regexp.source).to eq 'example\.com/path\w+'
      expect(subscription.match?(status)).to be true
    end
  end

  describe 'with match_hashtags only' do
    it 'matches a visible hashtag' do
      status = status_with('hello #fediverse', tags: %w(fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
    end

    it 'matches a tag that is not written in the body' do
      status = status_with('no tag in this text', tags: %w(fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
      expect(subscribe('#fediverse', match_hashtags: true).match?(status)).to be true
    end

    it 'keeps the ASCII end boundary inside a tag' do
      status = status_with('no tag in this text', tags: %w(foobar))

      expect(subscribe('foo', match_hashtags: true).match?(status)).to be false
      expect(subscribe('foobar', match_hashtags: true).match?(status)).to be true
    end

    it 'matches across an underscore separator inside a tag' do
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

    it 'follows ignorecase on the hashtag channel' do
      status = status_with('no tag in this text', tags: %w(Fediverse))

      expect(subscribe('fediverse', match_hashtags: true).match?(status)).to be true
      expect(subscribe('fediverse', match_hashtags: true, ignorecase: false).match?(status)).to be false
      expect(subscribe('Fediverse', match_hashtags: true, ignorecase: false).match?(status)).to be true
    end

    it 'does not match a URL' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('pathword', match_hashtags: true).match?(status)).to be false
      expect(subscribe('example.com', match_hashtags: true).match?(status)).to be false
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

    it 'lets a raw regexp match the hashtag token channel' do
      status = status_with('no tag in this text', tags: %w(fediverse))
      subscription = subscribe('\A#fedi\w+\z', regexp: true, match_hashtags: true)

      expect(subscription.keyword_regexp.source).to eq '\A#fedi\w+\z'
      expect(subscription.match?(status)).to be true
      expect(subscribe('\A#fedi\w+\z', regexp: true).match?(status)).to be false
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

    it 'does not let a keyword span two URLs' do
      first = status_with('the first')
      second = status_with('the second')
      status = Fabricate(:status, account: author, text: "see #{ActivityPub::TagManager.instance.url_for(first)} and #{ActivityPub::TagManager.instance.url_for(second)}")
      Fabricate(:status_reference, status: status, target_status: first)
      Fabricate(:status_reference, status: status, target_status: second)

      expect(status.filterable_urls.size).to be > 1
      expect(subscribe("#{first.id} #{second.id}", match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe(first.id.to_s, match_hashtags: true, match_urls: true).match?(status)).to be true
    end

    it 'does not let a keyword span two hashtags' do
      status = status_with('no tag in this text', tags: %w(alpha beta))

      expect(subscribe('alpha beta', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('#alpha #beta', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('alpha', match_hashtags: true, match_urls: true).match?(status)).to be true
    end

    it 'does not let a keyword span the body and a URL' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyword https', match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('bodyword pathword', match_hashtags: true, match_urls: true).match?(status)).to be false
    end

    it 'does not let a raw regexp span two channels' do
      status = status_with('bodyword https://example.com/pathword', tags: %w(fediverse))

      expect(subscribe('bodyword[\s\S]*pathword', regexp: true, match_hashtags: true, match_urls: true).match?(status)).to be false
      expect(subscribe('fediverse[\s\S]*pathword', regexp: true, match_hashtags: true, match_urls: true).match?(status)).to be false
    end
  end

  describe 'exclude_keyword' do
    it 'excludes on the URL channel only when match_urls is on' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyword', exclude_keyword: 'pathword', match_urls: true).match?(status)).to be false
      expect(subscribe('bodyword', exclude_keyword: 'pathword').match?(status)).to be true
    end

    it 'excludes on the hashtag channel only when match_hashtags is on' do
      status = status_with('bodyword here', tags: %w(spoiledtag))

      expect(subscribe('bodyword', exclude_keyword: 'spoiledtag', match_hashtags: true).match?(status)).to be false
      expect(subscribe('bodyword', exclude_keyword: 'spoiledtag').match?(status)).to be true
    end

    it 'excludes a hashtag match through a body keyword' do
      status = status_with('bodyword here', tags: %w(fediverse))

      expect(subscribe('fediverse', exclude_keyword: 'bodyword', match_hashtags: true).match?(status)).to be false
    end

    it 'uses the same regexp mode for exclusion' do
      status = status_with('bodyword https://example.com/pathword')

      expect(subscribe('bodyw.rd', exclude_keyword: 'path\w+', regexp: true, match_urls: true).match?(status)).to be false
      expect(subscribe('bodyw.rd', exclude_keyword: 'path\w+', regexp: true).match?(status)).to be true
    end
  end

  describe 'multiple comma keywords across channels' do
    it 'lets separate alternatives match separate channels' do
      status = status_with('plain body https://example.com/pathword', tags: %w(fediverse))
      keywords = 'bodyword,pathword,fediverse'

      expect(subscribe(keywords, match_hashtags: true, match_urls: true).match?(status)).to be true
      expect(subscribe('pathword,nothinghere', match_urls: true).match?(status)).to be true
      expect(subscribe('fediverse,nothinghere', match_hashtags: true).match?(status)).to be true
      expect(subscribe('nothinghere,stillnothing', match_hashtags: true, match_urls: true).match?(status)).to be false
    end

    it 'keeps each alternative boundary in the URL channel' do
      status = status_with('look https://example.com/pathword')

      expect(subscribe('ample,athword', match_urls: true).match?(status)).to be false
      expect(subscribe('ample,pathword', match_urls: true).match?(status)).to be true
    end
  end

  describe 'timeout and quoting on the new channels' do
    it 'keeps the match timeout on every generated context' do
      builder = KeywordSubscribe::PatternBuilder.new(ignorecase: true)

      KeywordSubscribe::PatternBuilder::CONTEXTS.each_key do |context|
        expect(builder.call(%w(foo), context).timeout).to eq 2.0
      end
    end

    it 'builds the body context exactly as the legacy pattern did' do
      legacy = '(?<![#])((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9]))|(?mix:(?<![\/\.])東京(?![\/\.])))'

      expect(KeywordSubscribe::PatternBuilder.new(ignorecase: true).call(%w(foo 東京), :body).source).to eq legacy
    end

    it 'drops only the hash and punctuation guards in the other contexts' do
      builder = KeywordSubscribe::PatternBuilder.new(ignorecase: true)

      expect(builder.call(%w(東京), :hashtag).source).to eq '((?mix:(?<![\/\.])東京(?![\/\.])))'
      expect(builder.call(%w(東京), :url).source).to eq '((?mix:東京))'
      expect(builder.call(%w(foo), :url).source).to eq '((?mix:(?<![A-Za-z0-9])foo(?![A-Za-z0-9])))'
    end
  end
end
