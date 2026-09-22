# frozen_string_literal: true

require 'rails_helper'

# Delivery-level coverage for the two Keyword Subscribe matching options. The
# assertions look at what FanOut actually enqueues, so a matcher that returns
# true but never reaches a feed cannot pass.
RSpec.describe FanOutOnWriteService, 'keyword subscribe delivery' do # rubocop:disable Metrics/BlockLength
  let(:author)     { Fabricate(:user, account: Fabricate(:account, username: 'author')).account }
  let(:subscriber) { Fabricate(:user, account: Fabricate(:account, username: 'subscriber')).account }
  let(:list)       { Fabricate(:list, account: subscriber) }

  # keyword= and exclude_keyword= normalize based on the regexp flag, so the flag
  # is assigned before them.
  def subscribe(keyword, **options)
    attributes = {
      account: subscriber,
      name: "subscription #{SecureRandom.hex(4)}",
      regexp: false,
      match_hashtags: false,
      match_urls: false,
      list_id: nil,
      exclude_keyword: '',
    }.merge(options)

    KeywordSubscribe.create!(attributes.merge(keyword: keyword))
  end

  def status_with(text, tags: [], visibility: :public)
    status = Fabricate(:status, account: author, text: text, visibility: visibility)
    tags.each { |name| status.tags << Fabricate(:tag, name: name) }
    status
  end

  def pushes_for(status)
    pushes = []

    allow(FeedInsertWorker).to receive(:push_bulk) do |collection, &block|
      collection.each { |item| pushes << block.call(item) }
    end

    described_class.new.call(status)
    pushes
  end

  def home_push(status)
    [status.id, subscriber.id, 'home']
  end

  def list_push(status)
    [status.id, list.id, 'list']
  end

  it 'delivers to a home subscriber matched by body text' do
    subscribe('bodyword')
    status = status_with('a bodyword here')

    expect(pushes_for(status)).to include home_push(status)
  end

  it 'delivers to a home subscriber matched only by a URL when match_urls is on' do
    subscribe('pathword', match_urls: true)
    status = status_with('look https://example.com/pathword')

    expect(pushes_for(status)).to include home_push(status)
  end

  it 'does not deliver the same URL subscription when match_urls is off' do
    subscribe('pathword')
    status = status_with('look https://example.com/pathword')

    expect(pushes_for(status)).not_to include home_push(status)
  end

  it 'inserts a URL-matched status into the home feed' do
    subscribe('pathword', match_urls: true)
    status = status_with('look https://example.com/pathword')

    described_class.new.call(status)

    expect(HomeFeed.new(subscriber).get(10).map(&:id)).to include status.id
  end

  it 'delivers to a list subscriber matched only by a hidden hashtag when match_hashtags is on' do
    subscribe('fediverse', match_hashtags: true, list_id: list.id)
    status = status_with('no tag in this text', tags: %w(fediverse))

    expect(pushes_for(status)).to include list_push(status)
  end

  it 'does not deliver the same hashtag subscription when match_hashtags is off' do
    subscribe('fediverse', list_id: list.id)
    status = status_with('no tag in this text', tags: %w(fediverse))

    expect(pushes_for(status)).not_to include list_push(status)
  end

  it 'stops delivery when exclude_keyword matches URL material' do
    subscribe('bodyword', exclude_keyword: 'pathword', match_urls: true)
    status = status_with('a bodyword and https://example.com/pathword')

    expect(pushes_for(status)).not_to include home_push(status)
  end

  it 'keeps delivery when the excluded URL keyword has no URL material to read' do
    subscribe('bodyword', exclude_keyword: 'pathword')
    status = status_with('a bodyword and https://example.com/pathword')

    expect(pushes_for(status)).to include home_push(status)
  end

  it 'stops delivery when exclude_keyword matches hashtag material' do
    subscribe('bodyword', exclude_keyword: 'spoiledtag', match_hashtags: true, list_id: list.id)
    status = status_with('a bodyword here', tags: %w(spoiledtag))

    expect(pushes_for(status)).not_to include list_push(status)
  end

  it 'keeps delivery when the excluded hashtag keyword has no hashtag material to read' do
    subscribe('bodyword', exclude_keyword: 'spoiledtag', list_id: list.id)
    status = status_with('a bodyword here', tags: %w(spoiledtag))

    expect(pushes_for(status)).to include list_push(status)
  end

  it 'keeps the visibility scope for a URL match' do
    subscribe('pathword', match_urls: true)
    status = status_with('look https://example.com/pathword', visibility: :private)

    expect(pushes_for(status)).not_to include home_push(status)
  end

  it 'keeps the visibility scope for a hashtag match' do
    subscribe('fediverse', match_hashtags: true, list_id: list.id)
    status = status_with('no tag in this text', tags: %w(fediverse), visibility: :private)

    expect(pushes_for(status)).not_to include list_push(status)
  end

  it 'does not keyword-deliver a reblog matched through the new options' do
    subscribe('pathword,fediverse', match_hashtags: true, match_urls: true, list_id: nil)
    original = status_with('look https://example.com/pathword', tags: %w(fediverse))
    booster = Fabricate(:user, account: Fabricate(:account, username: 'booster')).account
    reblog = Fabricate(:status, account: booster, reblog: original)

    pushes = pushes_for(reblog)

    expect(pushes).not_to include [reblog.id, subscriber.id, 'home']
    expect(pushes).not_to include [reblog.id, list.id, 'list']
  end

  it 'delivers a raw regexp subscription matched only by URL material when match_urls is on' do
    subscribe('example\.com/path\w+', regexp: true, match_urls: true)
    status = status_with('look https://example.com/pathword')

    expect(pushes_for(status)).to include home_push(status)
  end

  it 'does not deliver the same raw regexp subscription when match_urls is off' do
    subscribe('example\.com/path\w+', regexp: true)
    status = status_with('look https://example.com/pathword')

    expect(pushes_for(status)).not_to include home_push(status)
  end

  it 'does not deliver a raw regexp subscription matched only by a visible hashtag when match_hashtags is off' do
    subscribe('#fedi\w+', regexp: true)
    status = status_with('hello #fediverse', tags: %w(fediverse))

    expect(pushes_for(status)).not_to include home_push(status)
  end

  it 'delivers the same raw regexp subscription when match_hashtags is on' do
    subscribe('#fedi\w+', regexp: true, match_hashtags: true)
    status = status_with('hello #fediverse', tags: %w(fediverse))

    expect(pushes_for(status)).to include home_push(status)
  end

  it 'skips a media_only subscription for a status without media' do
    subscribe('pathword', match_urls: true).update!(media_only: true)
    status = status_with('look https://example.com/pathword')

    expect(pushes_for(status)).not_to include home_push(status)
  end

  # A follower already receives the status through ordinary follow delivery, so
  # the keyword scope still skips them. Asserted on the scope, because a push
  # for a follower is indistinguishable from follow delivery.
  it 'leaves a following subscriber out of the keyword scope' do
    subscriber.follow!(author)
    subscription = subscribe('pathword', match_urls: true)

    expect(KeywordSubscribe.without_local_followed_home(author)).not_to include subscription
  end
end
