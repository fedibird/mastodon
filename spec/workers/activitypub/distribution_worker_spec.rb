require 'rails_helper'

describe ActivityPub::DistributionWorker do
  subject { described_class.new }

  let(:status)   { Fabricate(:status) }
  let(:follower) { Fabricate(:account, protocol: :activitypub, inbox_url: 'http://example.com') }

  describe '#perform' do
    before do
      allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)

      follower.follow!(status.account)
    end

    context 'with public status' do
      before do
        status.update(visibility: :public)
      end

      it 'delivers to followers' do
        subject.perform(status.id)
        expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['http://example.com'])
      end
    end

    context 'with private status' do
      before do
        status.update(visibility: :private)
      end

      it 'delivers to followers' do
        subject.perform(status.id)
        expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['http://example.com'])
      end
    end

    context 'with limited status' do
      before do
        status.update(visibility: :limited)
        status.capability_tokens.create!
      end

      context 'standalone' do
        before do
          2.times do |i|
            status.mentions.create!(silent: true, account: Fabricate(:account, username: "bob#{i}", domain: "example#{i}.com", inbox_url: "https://example#{i}.com/inbox"))
          end
        end

        it 'delivers to personal inboxes' do
          subject.perform(status.id)
          expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://example0.com/inbox', 'https://example1.com/inbox'])
        end
      end

      context 'when it\'s a reply' do
        let(:conversation) { Fabricate(:conversation, uri: 'https://example.com/123', inbox_url: 'https://example.com/123/inbox') }
        let(:parent) { Fabricate(:status, visibility: :limited, account: Fabricate(:account, username: 'alice', domain: 'example.com', inbox_url: 'https://example.com/inbox'), conversation: conversation) }

        before do
          status.update(thread: parent, conversation: conversation)
        end

        it 'delivers to inbox of conversation only' do
          subject.perform(status.id)
          expect(ActivityPub::DeliveryWorker).to have_received(:perform_async).once
        end
      end
    end

    context 'with an ActivityPub audience target' do
      let(:group) do
        Fabricate(
          :account,
          username: 'group',
          domain: 'group.example',
          actor_type: 'Group',
          protocol: :activitypub,
          uri: 'https://group.example/users/group',
          inbox_url: 'https://group.example/users/group/inbox',
          shared_inbox_url: 'https://group.example/inbox',
          followers_url: 'https://group.example/users/group/followers'
        )
      end

      before do
        status.update!(visibility: :public, audience_account: group)
      end

      it 'delivers the create to the group actor inbox as well as followers' do
        delivered = []
        allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) { |inboxes| delivered.concat(inboxes) }

        subject.perform(status.id)

        expect(delivered).to include('http://example.com', group.inbox_url)
        expect(delivered.count(group.inbox_url)).to eq 1
        expect(delivered).not_to include(group.shared_inbox_url, group.followers_url)
        expect(group.following?(status.account)).to be false
      end

      it 'delivers a shared inbox and the group actor inbox only once when they are the same url' do
        group.update!(inbox_url: 'http://example.com')
        delivered = []
        allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) { |inboxes| delivered.concat(inboxes) }

        subject.perform(status.id)

        expect(delivered.count('http://example.com')).to eq 1
      end
    end

    context 'with direct status' do
      before do
        status.update(visibility: :direct)
      end

      it 'does nothing' do
        subject.perform(status.id)
        expect(ActivityPub::DeliveryWorker).to_not have_received(:push_bulk)
      end
    end
  end
end

describe 'ActivityPub::DistributionWorker group observation' do
  subject { ActivityPub::DistributionWorker.new }

  let(:author) { Fabricate(:user, admin: true).account }
  let(:group) do
    Fabricate(
      :account,
      username: 'technology',
      domain: 'lemmy.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://lemmy.example/c/technology',
      inbox_url: 'https://lemmy.example/c/technology/inbox',
      shared_inbox_url: 'https://lemmy.example/inbox'
    )
  end
  let(:status) { Fabricate(:status, account: author, visibility: :public, audience_account: group) }
  let(:follower) { Fabricate(:account, protocol: :activitypub, inbox_url: 'https://follower.example/inbox') }
  let(:observation_key) { PostingContext::GroupFederationObservation.key_for(status.id, group.id) }

  before do
    Node.create!(domain: 'lemmy.example', info: { 'software_name' => 'lemmy' })
    follower.follow!(author)
    Fabricate(:relay, inbox_url: 'https://relay.example/inbox', state: :accepted)
  end

  after do
    RedisConfiguration.with { |redis| redis.del(observation_key) }
  end

  def enable_observation(account)
    ClimateControl.modify(
      GROUP_FEDERATION_OBSERVATION_ENABLED: 'true',
      GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS: account.id.to_s
    ) { yield }
  end

  def capture_deliveries
    calls = []
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) do |inboxes, &block|
      calls << { inboxes: inboxes, jobs: inboxes.map { |inbox| block.call(inbox) } }
    end
    calls
  end

  it 'attaches the observation id only to the group actor inbox job' do
    calls = capture_deliveries

    enable_observation(author) { subject.perform(status.id) }

    group_jobs = calls.flat_map { |call| call[:jobs] }.select { |job| job[2] == group.inbox_url }
    other_jobs = calls.flat_map { |call| call[:jobs] }.reject { |job| job[2] == group.inbox_url }
    record = PostingContext::GroupFederationObservation.read(status.id, group.id)

    expect(calls.first[:inboxes]).to include(follower.inbox_url, group.inbox_url)
    expect(calls.first[:inboxes].count(group.inbox_url)).to eq 1
    expect(group_jobs.size).to eq 1
    expect(group_jobs.first[3]).to include('group_delivery_observation' => observation_key)
    expect(other_jobs.map { |job| job[3] }).to all(satisfy { |options| options.nil? || !options.key?('group_delivery_observation') })
    expect(calls.second[:inboxes]).to eq ['https://relay.example/inbox']
    expect(record['queue_observed']).to be true
    expect(record['adapter']).to eq 'lemmy_group'
    expect(record['activity_type']).to eq 'Create'
    expect(record['attempt_count']).to eq 0
  end

  it 'keeps one physical delivery when the group inbox is also a follower inbox' do
    group.update!(inbox_url: follower.inbox_url)
    calls = capture_deliveries

    enable_observation(author) { subject.perform(status.id) }

    audience_jobs = calls.first[:jobs].select { |job| job[2] == follower.inbox_url }

    expect(calls.first[:inboxes].count(follower.inbox_url)).to eq 1
    expect(audience_jobs.size).to eq 1
    expect(audience_jobs.first[3]).to include('group_delivery_observation' => PostingContext::GroupFederationObservation.key_for(status.id, group.id))
  end

  it 'initializes the record before enqueue and does not mark the queue when enqueue fails' do
    order = []
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) do
      order << JSON.parse(RedisConfiguration.with { |redis| redis.get(observation_key) })['queue_observed']
      raise Redis::ConnectionError
    end

    expect {
      enable_observation(author) { subject.perform(status.id) }
    }.to raise_error(Redis::ConnectionError)

    record = PostingContext::GroupFederationObservation.read(status.id, group.id)

    expect(order).to eq [false]
    expect(record['queue_observed']).to be false
    expect(record['http_2xx_observed']).to be false
    expect(record['terminal_failure']).to be false
  end

  it 'still delivers when observation storage is unavailable' do
    allow(PostingContext::GroupFederationObservation).to receive(:prepare).and_raise(Redis::ConnectionError)
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)

    expect {
      enable_observation(author) { subject.perform(status.id) }
    }.not_to raise_error

    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).at_least(:once)
  end

  it 'does not start observation for an ordinary public post or a non-admin author' do
    plain = Fabricate(:status, account: author, visibility: :public)
    outsider = Fabricate(:user, admin: false).account
    outsider_status = Fabricate(:status, account: outsider, visibility: :public, audience_account: group)
    calls = capture_deliveries

    enable_observation(author) do
      subject.perform(plain.id)
      ClimateControl.modify(GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS: outsider.id.to_s) do
        subject.perform(outsider_status.id)
      end
    end

    observed_jobs = calls.flat_map { |call| call[:jobs] }.select { |job| job[3].is_a?(Hash) && job[3].key?('group_delivery_observation') }

    expect(observed_jobs).to be_empty
    expect(PostingContext::GroupFederationObservation.read(plain.id, group.id)).to be_nil
    expect(PostingContext::GroupFederationObservation.read(outsider_status.id, group.id)).to be_nil
  end

  it 'does not observe private, unlisted, direct, or local-group posts' do
    local_group = Fabricate(:account, username: 'localgroup', actor_type: 'Group')
    samples = [
      Fabricate(:status, account: author, visibility: :private, audience_account: group),
      Fabricate(:status, account: author, visibility: :unlisted, audience_account: group),
      Fabricate(:status, account: author, visibility: :direct, audience_account: group),
      Fabricate(:status, account: author, visibility: :public, audience_account: local_group),
    ]
    calls = capture_deliveries

    enable_observation(author) { samples.each { |sample| subject.perform(sample.id) } }

    observed_jobs = calls.flat_map { |call| call[:jobs] }.select { |job| job[3].is_a?(Hash) && job[3].key?('group_delivery_observation') }

    expect(observed_jobs).to be_empty
    expect(samples.map { |sample| PostingContext::GroupFederationObservation.read(sample.id, sample.audience_account_id) }).to all(be_nil)
  end

  it 'does not reset stored HTTP evidence when the same status is distributed again' do
    calls = capture_deliveries

    enable_observation(author) do
      PostingContext::GroupFederationObservation.prepare(status, author)
      PostingContext::GroupFederationObservation.apply_attempt(
        observation_key,
        'outcome' => 'http_success',
        'http_status' => 200,
        'http_attempt' => true,
        'http_2xx' => true,
        'request_started_at' => Time.now.utc.iso8601(6),
        'observed_at' => Time.now.utc.iso8601
      )
      subject.perform(status.id)
    end

    record = PostingContext::GroupFederationObservation.read(status.id, group.id)

    expect(calls.first[:inboxes].count(group.inbox_url)).to eq 1
    expect(record['http_2xx_observed']).to be true
    expect(record['last_http_status']).to eq 200
    expect(record['queue_observed']).to be true
    expect(record['attempt_count']).to eq 1
  end
end
