# frozen_string_literal: true

require 'rails_helper'

# Characterization of Keyword Subscribe matching with both matching options off,
# which is the default for every new subscription.
#
# Sections marked LEGACY record behavior that predates the URL/hashtag matching
# options and must not change. The sections about hashtag material record where
# the options deliberately changed matching: with match_hashtags off, visible
# hashtag spans are masked out of the prepared string before either matching
# mode sees it, so the old weak `(?<![#])` guard is no longer the only thing
# keeping keywords out of hashtags. The enabled side of each case lives in
# spec/models/keyword_subscribe_matching_spec.rb.
RSpec.describe KeywordSubscribe, type: :model do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account) }

  # keyword= and exclude_keyword= normalize based on the regexp flag, so the flag
  # is assigned before them.
  def subscribe(keyword, **options)
    attributes = { account: account, regexp: false, ignorecase: true, match_hashtags: false, match_urls: false, exclude_keyword: '' }.merge(options)

    described_class.new(attributes.merge(keyword: keyword))
  end

  def matches?(keyword, text, **options)
    subscribe(keyword, **options).match?(text)
  end

  describe 'LEGACY keyword normalization' do
    it 'strips surrounding whitespace' do
      expect(subscribe('  foo  ').keyword).to eq 'foo'
    end

    it 'collapses repeated whitespace inside a keyword' do
      expect(subscribe("foo  \n bar").keyword).to eq 'foo bar'
    end

    it 'normalizes whitespace around commas' do
      expect(subscribe('foo , bar').keyword).to eq 'foo,bar'
    end

    it 'removes blank entries' do
      expect(subscribe('foo,,bar,').keyword).to eq 'foo,bar'
    end

    it 'removes duplicates' do
      expect(subscribe('foo,bar,foo').keyword).to eq 'foo,bar'
    end

    it 'normalizes exclude_keyword the same way' do
      expect(subscribe('foo', exclude_keyword: '  bar , baz ,bar ').exclude_keyword).to eq 'bar,baz'
    end

    it 'keeps a raw regexp source untouched' do
      expect(subscribe('  fo+ ,  o\s*x  ', regexp: true).keyword).to eq '  fo+ ,  o\s*x  '
    end

    it 'normalizes based on the regexp flag at assignment time' do
      late_flag = described_class.new(account: account, keyword: ' foo , bar ', regexp: true)

      expect(late_flag.keyword).to eq 'foo,bar'
    end

    it 'matches a space inside one keyword as one or more whitespace characters' do
      expect(matches?('foo bar', "foo \t\n bar")).to be true
      expect(matches?('foo bar', 'foobar')).to be false
    end
  end

  describe 'LEGACY ASCII boundaries' do
    it 'matches the bare keyword' do
      expect(matches?('foo', 'foo')).to be true
    end

    it 'matches a punctuation-delimited keyword' do
      expect(matches?('foo', 'say (foo) now')).to be true
    end

    it 'does not match a longer ASCII word' do
      expect(matches?('foo', 'foobar')).to be false
      expect(matches?('foo', 'barfoo')).to be false
    end

    it 'matches across a hyphen because a hyphen is not alphanumeric' do
      expect(matches?('foo', 'foo-bar')).to be true
      expect(matches?('bar', 'foo-bar')).to be true
    end

    it 'matches across an underscore because an underscore is not alphanumeric' do
      expect(matches?('foo', 'foo_bar')).to be true
      expect(matches?('bar', 'foo_bar')).to be true
    end

    it 'follows ignorecase' do
      expect(matches?('foo', 'FOO')).to be true
      expect(matches?('foo', 'FOO', ignorecase: false)).to be false
      expect(matches?('FOO', 'FOO', ignorecase: false)).to be true
    end
  end

  describe 'LEGACY punctuation-edged keywords' do
    it 'drops the start boundary for a keyword starting with a dot' do
      expect(matches?('.foo', 'x.foo')).to be true
      expect(matches?('.foo', '.foobar')).to be false
    end

    it 'drops the end boundary for a keyword ending with a dot' do
      expect(matches?('foo.', 'foo.bar')).to be true
      expect(matches?('foo.', 'xfoo.')).to be false
    end

    it 'drops the start boundary for a keyword starting with a slash' do
      expect(matches?('/foo', 'a/foo')).to be true
      expect(matches?('/foo', '/foobar')).to be false
    end

    it 'drops the end boundary for a keyword ending with a slash' do
      expect(matches?('foo/', 'foo/bar')).to be true
      expect(matches?('foo/', 'xfoo/')).to be false
    end
  end

  describe 'LEGACY non-ASCII matching' do
    it 'matches a Japanese keyword as a substring' do
      expect(matches?('東京', '東京')).to be true
      expect(matches?('東京', '東京都の話')).to be true
      expect(matches?('東京', '西東京市')).to be true
    end

    it 'matches a Japanese keyword next to punctuation and whitespace' do
      expect(matches?('東京', '「東京」')).to be true
      expect(matches?('東京', '話 東京 です')).to be true
    end

    it 'refuses a Japanese keyword touching a slash or a dot' do
      expect(matches?('東京', '/東京')).to be false
      expect(matches?('東京', '東京/')).to be false
      expect(matches?('東京', '.東京')).to be false
      expect(matches?('東京', '東京.')).to be false
    end

    it 'matches whitespace inside a Japanese keyword' do
      expect(matches?('東 京', "東 \t 京")).to be true
    end
  end

  describe 'LEGACY hashtag guard' do
    it 'does not match a keyword written immediately after the hash' do
      expect(matches?('foo', '#foo')).to be false
      expect(matches?('foo', 'hello #foo')).to be false
      expect(matches?('東京', '#東京')).to be false
    end

    it 'does not match a keyword that is a prefix of a longer ASCII tag' do
      expect(matches?('foo', '#foobar')).to be false
    end
  end

  # The old guard only refused a keyword written immediately after the hash, so
  # `bar` matched `#foo_bar` and `京` matched `#東京`. With match_hashtags off the
  # whole hashtag span is masked out before matching, which closes that leak and
  # also stops a keyword that spells a hash, because no hashtag material is
  # presented at all. match_hashtags is the option that puts it back.
  describe 'hashtag material with match_hashtags off' do
    it 'no longer matches an ASCII keyword after a separator inside a tag' do
      expect(matches?('bar', '#foo_bar')).to be false
    end

    it 'no longer matches a Japanese keyword inside a longer tag' do
      expect(matches?('京', '#東京')).to be false
      expect(matches?('東京', '#西東京')).to be false
    end

    it 'still matches the same words outside a hashtag' do
      expect(matches?('bar', 'foo_bar')).to be true
      expect(matches?('京', '東京')).to be true
      expect(matches?('bar', 'a #foo_bar and bar')).to be true
    end

    it 'no longer matches a keyword that spells a hash' do
      expect(matches?('#foo', 'hello #foo')).to be false
      expect(matches?('#foo_bar', 'hello #foo_bar')).to be false
    end

    it 'matches a keyword that spells a hash once match_hashtags is on' do
      expect(matches?('#foo', 'hello #foo', match_hashtags: true)).to be true
      expect(matches?('#foo_bar', 'hello #foo_bar', match_hashtags: true)).to be true
    end

    it 'does not let a masked hashtag act as whitespace inside a keyword' do
      expect(matches?('foo bar', 'foo #tag bar')).to be false
      expect(matches?('foo bar', 'foo bar')).to be true
    end

    it 'leaves a hash that is not a hashtag in the body' do
      expect(matches?('1', '#1')).to be false
      expect(matches?('c#', 'C# code')).to be true
    end
  end

  describe 'LEGACY regexp mode' do
    it 'uses the source as written' do
      expect(matches?('fo+o', 'fooo', regexp: true)).to be true
      expect(matches?('^foo$', 'foo', regexp: true)).to be true
      expect(matches?('^foo$', 'a foo b', regexp: true)).to be false
    end

    it 'applies no generated word boundary' do
      expect(matches?('foo', 'foobar', regexp: true)).to be true
    end

    it 'follows ignorecase' do
      expect(matches?('foo', 'FOO', regexp: true)).to be true
      expect(matches?('foo', 'FOO', regexp: true, ignorecase: false)).to be false
    end

    # Revised in this change: a raw regexp is matched against the same prepared
    # string as a generated keyword, so with match_hashtags off it no longer
    # reaches visible hashtag material either.
    it 'does not match visible hashtag text while match_hashtags is off' do
      expect(matches?('foo', '#foo', regexp: true)).to be false
      expect(matches?('foo', '#foo', regexp: true, match_hashtags: true)).to be true
    end

    it 'rejects an invalid source' do
      record = subscribe('(foo', regexp: true)

      expect(record.valid?).to be false
      expect(record.errors[:base].join).to include 'Regular expression error'
    end

    it 'rejects an invalid exclude source' do
      record = subscribe('foo', exclude_keyword: '(bar', regexp: true)

      expect(record.valid?).to be false
    end

    it 'accepts a valid source' do
      expect(subscribe('fo+o', exclude_keyword: 'ba+r', regexp: true).valid?).to be true
    end
  end

  describe 'LEGACY exclude_keyword' do
    it 'suppresses a positive match' do
      expect(matches?('foo', 'foo and bar', exclude_keyword: 'bar')).to be false
      expect(matches?('foo', 'foo alone', exclude_keyword: 'bar')).to be true
    end

    it 'uses the same case option as the positive keyword' do
      expect(matches?('foo', 'foo BAR', exclude_keyword: 'bar')).to be false
      expect(matches?('foo', 'foo bar', exclude_keyword: 'bar', ignorecase: false)).to be false
      expect(matches?('foo', 'foo BAR', exclude_keyword: 'bar', ignorecase: false)).to be true
    end

    it 'uses the same regexp mode as the positive keyword' do
      expect(matches?('fo+o', 'fooo bar', exclude_keyword: 'ba+r', regexp: true)).to be false
    end
  end

  describe 'LEGACY multiple comma keywords' do
    it 'matches any alternative and keeps each boundary' do
      expect(matches?('foo,東京,c++', 'about c++')).to be true
      expect(matches?('foo,東京,c++', '東京都')).to be true
      expect(matches?('foo,東京,c++', 'foo')).to be true
      expect(matches?('foo,東京,c++', 'foobar')).to be false
    end
  end

  describe 'LEGACY metacharacter safety' do
    it 'quotes regex metacharacters in generated patterns' do
      expect(matches?('c++', 'in c++ code')).to be true
      expect(matches?('c++', 'in c code')).to be false
      expect(matches?('a.b', 'a.b')).to be true
      expect(matches?('a.b', 'axb')).to be false
      expect(matches?('foo/bar', 'see foo/bar')).to be true
      expect(matches?('(foo)', 'say (foo)')).to be true
      expect(matches?('(foo)', 'say foo')).to be false
      expect(matches?('[bar]', 'say [bar]')).to be true
      expect(matches?('?', 'what?')).to be true
    end

    it 'keeps a regex timeout on generated patterns' do
      expect(subscribe('foo').keyword_regexp.timeout).to eq 2.0
      expect(subscribe('foo', exclude_keyword: 'bar').exclude_keyword_regexp.timeout).to eq 2.0
    end

    it 'keeps a regex timeout on raw patterns' do
      expect(subscribe('fo+o', regexp: true).keyword_regexp.timeout).to eq 2.0
    end
  end

  describe 'LEGACY status text channel' do
    let(:local_account) { Fabricate(:account, domain: nil, username: 'alice') }

    it 'does not expose URLs through searchable_text' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/pathword')

      expect(matches?('example.com', status.searchable_text)).to be false
      expect(matches?('pathword', status.searchable_text)).to be false
      expect(matches?('look', status.searchable_text)).to be true
    end

    it 'does not expose an associated tag that is absent from the body' do
      status = Fabricate(:status, account: local_account, text: 'no tag written here')
      status.tags << Fabricate(:tag, name: 'fediverse')

      expect(matches?('fediverse', status.searchable_text)).to be false
      expect(matches?('#fediverse', status.searchable_text)).to be false
    end

    it 'exposes spoiler text, poll options, and media descriptions' do
      status = Fabricate(:status, account: local_account, text: 'body', spoiler_text: 'spoilerword')
      poll = Fabricate(:poll, account: local_account, status: status, options: %w(Alphaword Bravoword))
      status.update!(poll_id: poll.id)

      expect(matches?('spoilerword', status.searchable_text)).to be true
      expect(matches?('Alphaword', status.searchable_text)).to be true
    end
  end

  describe 'LEGACY class-level matching' do
    it 'finds an active subscription for the account' do
      described_class.create!(account: account, keyword: 'foo', name: 'one')

      expect(described_class.match?('foo', account_id: account.id)).to be true
      expect(described_class.match?('bar', account_id: account.id)).to be false
    end

    it 'ignores disabled subscriptions' do
      described_class.create!(account: account, keyword: 'foo', name: 'one', disabled: true)

      expect(described_class.match?('foo', account_id: account.id)).to be false
    end

    it 'scopes by list' do
      list = Fabricate(:list, account: account)
      described_class.create!(account: account, keyword: 'foo', name: 'one', list_id: list.id)

      expect(described_class.match?('foo', account_id: account.id)).to be false
      expect(described_class.match?('foo', account_id: account.id, list_id: list.id)).to be true
    end
  end
end
