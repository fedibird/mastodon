# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedInsertWorker, 'delivery reason' do
  let(:author) { Fabricate(:account, username: 'delivery_author') }
  let(:parent_author) { Fabricate(:account, username: 'delivery_parent') }
  let(:receiver_account) { Fabricate(:account, username: 'delivery_receiver') }
  let!(:receiver) { Fabricate(:user, account: receiver_account, current_sign_in_at: Time.now.utc) }
  let(:parent) { Fabricate(:status, account: parent_author, text: 'parent', visibility: :public) }
  let(:reply) { Fabricate(:status, account: author, text: 'say alpha please', thread: parent, visibility: :public) }
  let!(:subscription) { KeywordSubscribe.create!(account: receiver_account, keyword: 'alpha', name: 'rule') }

  around do |example|
    previous = ENV.fetch(FeedDelivery::MODE_ENV, nil)
    FeedDelivery::Metrics.reset!
    example.run
    ENV[FeedDelivery::MODE_ENV] = previous
    FeedDelivery::Metrics.reset!
  end

  def home_ids
    HomeFeed.new(receiver_account).get(20).map(&:id)
  end

  def options_for(status, subscription, update: false, ignore: nil)
    evidence = FeedDelivery::Evidence.build(subscription: subscription, ignore_block_subscription: ignore, status: status)
    options = evidence.to_options
    options['update'] = true if update
    options
  end

  def perform(status = reply, options = {})
    described_class.new.perform(status.id, receiver_account.id, 'home', options)
  end

  it 'admits a legacy job from the current keyword rules when enforce is on' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'

    perform

    expect(home_ids).to include(reply.id)
    expect(FeedDelivery::Metrics.snapshot['kw|qual=reply|result=evidence']).to be_nil
  end

  it 'ignores evidence while the mode is off' do
    ENV[FeedDelivery::MODE_ENV] = 'off'
    other = Fabricate(:status, account: author, text: 'no keyword', thread: parent, visibility: :public)

    perform(other, options_for(other, subscription))

    expect(home_ids).not_to include(other.id)
  end

  it 'skips the keyword re-match when enforce has fresh evidence' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    expect(KeywordSubscribe).not_to receive(:match?)

    perform(reply, options_for(reply, subscription))

    expect(home_ids).to include(reply.id)
    expect(FeedDelivery::Metrics.snapshot['kw|qual=reply|result=evidence']).to eq 1
  end

  it 'keeps the legacy rejection in shadow when fresh evidence disagrees' do
    ENV[FeedDelivery::MODE_ENV] = 'shadow'
    other = Fabricate(:status, account: author, text: 'no keyword', thread: parent, visibility: :public)

    perform(other, options_for(other, subscription))

    expect(home_ids).not_to include(other.id)
    expect(FeedDelivery::Metrics.snapshot['kw|qual=reply|result=disagree']).to eq 1
  end

  it 'does not let keyword evidence bypass a block or a mute' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    receiver_account.block!(author)

    perform(reply, options_for(reply, subscription))

    expect(home_ids).not_to include(reply.id)

    receiver_account.unblock!(author)
    receiver_account.mute!(author)
    perform(reply, options_for(reply, subscription))

    expect(home_ids).not_to include(reply.id)
  end

  it 'falls back after the recorded rule is deleted and still admits another match' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    other = KeywordSubscribe.create!(account: receiver_account, keyword: 'alpha', name: 'other', exclude_keyword: 'zzz')
    evidence = FeedDelivery::KeywordScan.collect([subscription, other], KeywordSubscribe::MatchingText.new(status: reply), status: reply)
    subscription.destroy!

    perform(reply, evidence.to_options)

    expect(home_ids).to include(reply.id)
    expect(FeedDelivery::Metrics.snapshot['kw|qual=reply|result=fallback']).to eq 1
  end

  it 'drops a stale reply when no current rule matches' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    options = options_for(reply, subscription)
    subscription.update!(keyword: 'beta')

    perform(reply, options)

    expect(home_ids).not_to include(reply.id)
  end

  it 'unpushes an update when the edited status no longer matches the old evidence' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    perform(reply, options_for(reply, subscription))
    expect(home_ids).to include(reply.id)

    stale = options_for(reply, subscription, update: true)
    reply.update!(text: 'no keyword', edited_at: Time.now.utc)

    perform(reply, stale)

    expect(home_ids).not_to include(reply.id)
  end

  it 'keeps the status when a stale job is retried after a newer edit that still matches' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    original = options_for(reply, subscription, update: true)
    reply.update!(text: 'alpha revised', edited_at: Time.now.utc)
    revised = options_for(reply.reload, subscription.reload, update: true)

    perform(reply, revised)
    perform(reply, original)

    expect(home_ids.count(reply.id)).to eq 1
  end

  it 'uses the priority worker with the same enforce semantics' do
    ENV[FeedDelivery::MODE_ENV] = 'enforce'
    expect(KeywordSubscribe).not_to receive(:match?)

    PriorityFeedInsertWorker.new.perform(reply.id, receiver_account.id, 'home', options_for(reply, subscription))

    expect(home_ids).to include(reply.id)
  end

  context 'with a domain block' do
    let(:author) { Fabricate(:account, username: 'remote_author', domain: 'keyword.example') }

    before do
      receiver_account.block_domain!(author.domain)
    end

    it 'uses a fresh ignore-block rule without a second match' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'
      subscription.update!(ignore_block: true)
      expect(KeywordSubscribe).not_to receive(:match?)

      perform(reply, options_for(reply.reload, subscription.reload, ignore: subscription))

      expect(home_ids).to include(reply.id)
      expect(FeedDelivery::Metrics.snapshot['kw|qual=ignore_block|result=evidence']).to eq 1
    end

    it 'does not treat an ordinary keyword match as an ignore-block match' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'

      perform(reply, options_for(reply, subscription))

      expect(home_ids).not_to include(reply.id)
      expect(FeedDelivery::Metrics.snapshot['kw|qual=ignore_block|result=fallback']).to eq 1
    end

    it 'falls back and admits when another ignore-block rule still matches' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'
      other = KeywordSubscribe.create!(account: receiver_account, keyword: 'alpha', name: 'blocked', ignore_block: true, exclude_keyword: 'zzz')
      options = options_for(reply, subscription)

      perform(reply, options)

      expect(other).to be_ignore_block
      expect(home_ids).to include(reply.id)
      expect(FeedDelivery::Metrics.snapshot['kw|qual=ignore_block|result=fallback']).to eq 1
    end
  end

  context 'with a list' do
    let(:list) { Fabricate(:list, account: receiver_account, title: 'Delivery') }
    let(:status) { Fabricate(:status, account: author, text: 'plain list post', visibility: :public) }

    def perform_list
      described_class.new.perform(status.id, list.id, 'list')
    end

    it 'builds the list crutches once when enforce reuses the decision' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'
      expect(FeedManager.instance).to receive(:build_crutches).once.and_call_original

      perform_list

      expect(ListFeed.new(list).get(20).map(&:id)).to include(status.id)
      expect(FeedDelivery::Metrics.snapshot).to include(
        'crutches|event=build' => 1,
        'list|result=reuse' => 1
      )
    end

    it 'keeps both list checks while shadow is comparing them' do
      ENV[FeedDelivery::MODE_ENV] = 'shadow'
      expect(FeedManager.instance).to receive(:build_crutches).twice.and_call_original

      perform_list

      expect(ListFeed.new(list).get(20).map(&:id)).to include(status.id)
      expect(FeedDelivery::Metrics.snapshot).to include(
        'crutches|event=build' => 2,
        'list|result=agree' => 1
      )
    end

    it 'keeps both list checks while the mode is off' do
      ENV[FeedDelivery::MODE_ENV] = 'off'
      expect(FeedManager.instance).to receive(:build_crutches).twice.and_call_original

      perform_list

      expect(ListFeed.new(list).get(20).map(&:id)).to include(status.id)
      expect(FeedDelivery::Metrics.snapshot).to eq({})
    end

    it 'admits a list reply from fresh keyword evidence without a re-match' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'
      list.update!(replies_policy: :none)
      rule = KeywordSubscribe.create!(account: receiver_account, keyword: 'alpha', name: 'list-rule', list: list, exclude_keyword: 'zzz')
      evidence = FeedDelivery::KeywordScan.collect([rule], KeywordSubscribe::MatchingText.new(status: reply), status: reply)
      expect(KeywordSubscribe).not_to receive(:match?)

      described_class.new.perform(reply.id, list.id, 'list', evidence.to_options)

      expect(ListFeed.new(list).get(20).map(&:id)).to include(reply.id)
      expect(FeedDelivery::Metrics.snapshot['list|result=reuse']).to eq 1
    end

    it 'still filters a direct list insert when a caller passes a validated hash' do
      ENV[FeedDelivery::MODE_ENV] = 'enforce'
      list.update!(replies_policy: :none)
      rejected = Fabricate(:status, account: author, text: 'Nay', thread: parent, visibility: :public)

      expect(FeedManager.instance.push_to_list(list, rejected, decision: { 'validated' => true })).to be false
      expect(ListFeed.new(list).get(20).map(&:id)).not_to include(rejected.id)
    end
  end
end
