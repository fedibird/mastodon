# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, 'delivery reason' do
  let(:author) { Fabricate(:account, username: 'reason_author') }
  let(:subscriber) { Fabricate(:account, username: 'reason_subscriber') }
  let(:list) { Fabricate(:list, account: subscriber, title: 'Reason') }

  around do |example|
    previous = ENV.fetch(FeedDelivery::MODE_ENV, nil)
    FeedDelivery::Metrics.reset!
    example.run
    ENV[FeedDelivery::MODE_ENV] = previous
    FeedDelivery::Metrics.reset!
  end

  def subscribe(keyword, **options)
    KeywordSubscribe.create!({ account: subscriber, name: "rule #{SecureRandom.hex(4)}", keyword: keyword }.merge(options))
  end

  def capture(worker, status, update: false)
    pushes = []
    allow(worker).to receive(:push_bulk) do |collection, &block|
      collection.each { |item| pushes << block.call(item) }
    end
    described_class.new.call(status, update: update)
    pushes
  end

  it 'keeps the legacy job arguments while the mode is off' do
    ENV[FeedDelivery::MODE_ENV] = 'off'
    subscribe('alpha')
    status = Fabricate(:status, account: author, text: 'say alpha', visibility: :public)

    expect(capture(FeedInsertWorker, status)).to include([status.id, subscriber.id, 'home'])
    expect(FeedDelivery::Metrics.snapshot).to eq({})
  end

  it 'puts keyword evidence on home and list jobs without the keyword text' do
    ENV[FeedDelivery::MODE_ENV] = 'shadow'
    subscribe('alpha')
    subscribe('alpha', list_id: list.id, exclude_keyword: 'zzz')
    status = Fabricate(:status, account: author, text: 'say alpha', visibility: :public)

    home = capture(FeedInsertWorker, status).find { |push| push[1] == subscriber.id && push[2] == 'home' }
    list_push = nil
    allow(FeedInsertWorker).to receive(:push_bulk) do |collection, &block|
      collection.each do |item|
        args = block.call(item)
        list_push = args if args[2] == 'list' && args[1] == list.id
      end
    end
    described_class.new.call(status)

    expect(home[0]).to eq status.id
    expect(home[3]['reason']).to eq 'keyword'
    expect(home[3]['v']).to eq 1
    expect(home[3]['evidence']['account_id']).to eq subscriber.id
    expect(home[3]['evidence']['list_id']).to be_nil
    expect(JSON.generate(home[3])).not_to include('alpha')
    expect(list_push[3]['evidence']['list_id']).to eq list.id
    expect(list_push[3]['evidence']['account_id']).to eq subscriber.id
    expect(FeedDelivery::Metrics.snapshot['job|reason=keyword']).to be >= 2
  end

  it 'marks update jobs and uses the priority worker with the same evidence' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    author.high_priority!
    subscribe('alpha', ignore_block: true)
    status = Fabricate(:status, account: author, text: 'say alpha', visibility: :public)

    push = capture(PriorityFeedInsertWorker, status, update: true).find { |item| item[1] == subscriber.id && item[2] == 'home' }

    expect(push[3]['update']).to be true
    expect(push[3]['evidence']['ignore_block_subscription_id']).to be_present
    expect(push[3]['evidence']['subscription_id']).to eq push[3]['evidence']['ignore_block_subscription_id']
  end

  it 'still delivers a keyword subscriber who is not a follower only once per feed' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    subscribe('alpha')
    status = Fabricate(:status, account: author, text: 'say alpha', visibility: :public)

    homes = capture(FeedInsertWorker, status).select { |push| push[2] == 'home' && push[1] == subscriber.id }

    expect(homes.size).to eq 1
  end
end
