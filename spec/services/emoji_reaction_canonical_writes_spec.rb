# frozen_string_literal: true

require 'rails_helper'

# P1b-1a. Both flags default off. The off/off path must keep today's side
# effects and must not call Status#proper. On, the row, the cap, and undo use
# the original status, and a repeat PUT does not repeat side effects.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Emoji reaction canonical writes' do
  let(:author_user) { Fabricate(:user) }
  let(:author) { author_user.account }
  let(:reactor) { Fabricate(:account) }
  let(:booster) { Fabricate(:account) }

  def with_flags(canonical:, idempotent:, &block)
    ClimateControl.modify(
      {
        'EMOJI_REACTION_CANONICAL_WRITES' => canonical ? 'true' : nil,
        'EMOJI_REACTION_IDEMPOTENT_RETRY' => idempotent ? 'true' : nil,
      },
      &block
    )
  end

  def with_cap(value)
    previous = Setting.reaction_max_per_account
    Setting.reaction_max_per_account = value
    yield
  ensure
    Setting.reaction_max_per_account = previous
  end

  def react(status, emoji = '👍')
    EmojiReactionService.new.call(reactor, status, emoji)
  end

  def unreact(status, emoji = '👍', **options)
    UnEmojiReactionService.new.call(reactor, status, emoji, **options)
  end

  def boost_of(status, account: booster)
    Fabricate(:status, account: account, reblog: status, text: '')
  end

  def reaction_rows
    EmojiReaction.where(account: reactor)
  end

  def distribution_jobs
    ActivityPub::CustomEmojiDistributionWorker.jobs
  end

  def delivery_jobs
    ActivityPub::DeliveryWorker.jobs
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  before do
    ActivityPub::CustomEmojiDistributionWorker.jobs.clear
    ActivityPub::DeliveryWorker.jobs.clear
  end

  describe 'with both flags off' do
    it 'does not call Status#proper and still stores a boost reaction on the original' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)
      allow(wrapper).to receive(:proper).and_call_original

      with_flags(canonical: false, idempotent: false) do
        expect(react(wrapper).status_id).to eq status.id
      end

      expect(wrapper).not_to have_received(:proper)
    end

    it 'repeats notification, distribution, friendship, and not moderation' do
      status = Fabricate(:status, account: author)
      allow(PotentialFriendshipTracker).to receive(:record)

      with_flags(canonical: false, idempotent: false) do
        expect { react(status) }.to change { Notification.where(activity_type: 'EmojiReaction').count }.by(1)
          .and change(ModerationInteractionEvent, :count).by(1)
        expect(distribution_jobs.size).to eq 1
        expect(PotentialFriendshipTracker).to have_received(:record).with(reactor.id, author.id, :emoji_reaction)

        expect { react(status) }.to change { Notification.where(activity_type: 'EmojiReaction').count }.by(1)
          .and change(ModerationInteractionEvent, :count).by(0)
        expect(distribution_jobs.size).to eq 2
        expect(reaction_rows.count).to eq 1
      end
    end

    it 'keeps the legacy boost errors: 422 at the cap, and 404 under it' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_flags(canonical: false, idempotent: false) do
        react(status)
        expect { react(wrapper) }.to raise_error(ActiveRecord::RecordInvalid)
        expect(reaction_rows.count).to eq 1

        with_cap(2) do
          expect { react(wrapper) }.to raise_error(ActiveRecord::RecordNotFound)
        end
        expect(reaction_rows.count).to eq 1
      end
    end
  end

  describe 'canonical writes only' do
    it 'keeps one row on the original across either order and repeats side effects' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_flags(canonical: true, idempotent: false) do
        react(status)
        react(wrapper)
        react(status)
        expect(reaction_rows.pluck(:status_id)).to eq [status.id]
        expect(distribution_jobs.size).to eq 3

        distribution_jobs.clear
        other = Fabricate(:status, account: author)
        other_wrapper = boost_of(other)
        react(other_wrapper)
        react(other)
        react(other_wrapper)
        expect(EmojiReaction.where(account: reactor, status: other).count).to eq 1
        expect(distribution_jobs.size).to eq 3
      end
    end

    it 'lets a repeat succeed at the cap without inserting' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_flags(canonical: true, idempotent: false) do
        react(status)
        expect { react(wrapper) }.not_to raise_error
        expect { react(status, '🎉') }.to raise_error(ActiveRecord::RecordInvalid)
        expect(reaction_rows.count).to eq 1
      end
    end

    it 'removes the original row through a boost, one emoji or all of them, and ignores a missing emoji' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_cap(2) do
        with_flags(canonical: true, idempotent: false) do
        react(wrapper, '👍')
        react(status, '🎉')
        unreact(wrapper, '👍', shortcode_only: true)
        expect(reaction_rows.pluck(:name)).to eq ['🎉']

        expect { unreact(wrapper, '👍', shortcode_only: true) }.not_to raise_error
        expect(reaction_rows.pluck(:name)).to eq ['🎉']

        unreact(wrapper, nil)
        expect(reaction_rows).to be_empty
        end
      end
    end
  end

  describe 'idempotent retry only' do
    it 'does not repeat side effects for the same status id' do
      status = Fabricate(:status, account: author)
      allow(PotentialFriendshipTracker).to receive(:record)
      allow(ActivityTracker).to receive(:increment)

      with_flags(canonical: false, idempotent: true) do
        react(status)
        distribution_jobs.clear
        expect(PotentialFriendshipTracker).to have_received(:record).once

        expect { react(status) }.not_to change { Notification.where(activity_type: 'EmojiReaction').count }
        expect(distribution_jobs).to be_empty
        expect(ModerationInteractionEvent.where(event_type: 'reaction').count).to eq 1
        expect(PotentialFriendshipTracker).to have_received(:record).once
        expect(ActivityTracker).to have_received(:increment).with('activity:interactions').once
      end
    end

    it 'still 422s a boost repeat at the cap, and recovers a boost repeat under the cap' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_flags(canonical: false, idempotent: true) do
        react(wrapper)
        distribution_jobs.clear
        expect { react(wrapper) }.to raise_error(ActiveRecord::RecordInvalid)
        expect(distribution_jobs).to be_empty

        with_cap(2) do
          expect(react(wrapper).status_id).to eq status.id
        end
        expect(distribution_jobs).to be_empty
        expect(reaction_rows.count).to eq 1
      end
    end
  end

  describe 'both flags on' do
    it 'stores one row and delivers once for either PUT order' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)
      allow(PotentialFriendshipTracker).to receive(:record)

      with_flags(canonical: true, idempotent: true) do
        react(status)
        react(wrapper)
        react(status)
        expect(reaction_rows.pluck(:status_id)).to eq [status.id]
        expect(distribution_jobs.size).to eq 1
        expect(Notification.where(activity_type: 'EmojiReaction').count).to eq 1
        expect(PotentialFriendshipTracker).to have_received(:record).once

        distribution_jobs.clear
        Notification.delete_all
        other = Fabricate(:status, account: author)
        other_wrapper = boost_of(other)
        react(other_wrapper)
        react(other)
        react(other_wrapper)
        expect(EmojiReaction.where(account: reactor, status_id: other.id).count).to eq 1
        expect(distribution_jobs.size).to eq 1
      end
    end

    it 'succeeds a repeat at the cap and does not insert' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)

      with_flags(canonical: true, idempotent: true) do
        react(status)
        before = reaction_rows.pluck(:id)
        expect(react(wrapper)).to be_persisted
        expect(react(status)).to be_persisted
        expect(reaction_rows.pluck(:id)).to eq before
        expect { react(status, '🎉') }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it 're-reads a lost insert inside an outer transaction and skips side effects' do
      status = Fabricate(:status, account: author)
      with_cap(2) do
      existing = EmojiReaction.create!(account: reactor, status: status, name: '👍')
      attrs = { account_id: reactor.id, status_id: status.id, name: '👍' }
      lookups = 0
      allow(EmojiReaction).to receive(:find_by).and_wrap_original do |method, *args|
        lookups += 1
        lookups == 1 && args.first == attrs ? nil : method.call(*args)
      end
      allow(PotentialFriendshipTracker).to receive(:record)

      reaction = nil
      with_flags(canonical: true, idempotent: true) do
        ActiveRecord::Base.transaction do
          expect { reaction = react(status) }.not_to raise_error
          expect(reaction.id).to eq existing.id
          expect(EmojiReaction.where(attrs).count).to eq 1
          expect(Status.find(status.id).id).to eq status.id
        end
      end

      expect(lookups).to be >= 2
      expect(distribution_jobs).to be_empty
      expect(Notification.where(activity_type: 'EmojiReaction')).to be_empty
      expect(PotentialFriendshipTracker).not_to have_received(:record)
      expect(ModerationInteractionEvent.count).to eq 0
      end
    end

    it 'returns nil when a lost insert has no visible row' do
      status = Fabricate(:status, account: author)
      allow(EmojiReaction).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      with_flags(canonical: true, idempotent: true) do
        expect(react(status)).to be_nil
      end
      expect(reaction_rows).to be_empty
    end

    it 'propagates an unexpected create error' do
      status = Fabricate(:status, account: author)
      allow(EmojiReaction).to receive(:create!).and_raise(RuntimeError, 'boom')

      with_flags(canonical: true, idempotent: true) do
        expect { react(status) }.to raise_error(RuntimeError, 'boom')
      end
    end

    it 'checks remote custom emoji availability on the original' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)
      remote = Fabricate(:custom_emoji, shortcode: 'remoteblob', domain: 'emoji.example')
      EmojiReaction.create!(account: Fabricate(:account), status: status, name: 'remoteblob', custom_emoji: remote)

      with_flags(canonical: false, idempotent: false) do
        expect(react(wrapper, 'remoteblob@emoji.example')).to be_nil
      end
      expect(reaction_rows).to be_empty

      with_flags(canonical: true, idempotent: true) do
        expect(react(wrapper, 'remoteblob@emoji.example').status_id).to eq status.id
      end
    end

    it 'keeps the 200 no-op when a remote custom emoji is not already on the status' do
      status = Fabricate(:status, account: author)
      Fabricate(:custom_emoji, shortcode: 'remoteblob', domain: 'emoji.example')

      with_flags(canonical: true, idempotent: true) do
        expect(react(status, 'remoteblob@emoji.example')).to be_nil
      end
      expect(reaction_rows).to be_empty
    end

    it 'still rejects an unknown unicode emoji' do
      status = Fabricate(:status, account: author)

      [false, true].each do |enabled|
        with_flags(canonical: enabled, idempotent: enabled) do
          expect { react(status, 'not-an-emoji') }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end

    it 'leaves an expired original on the wrapper, matching before_validation' do
      status = Fabricate(:status, account: author)
      wrapper = boost_of(status)
      status.update_columns(expired_at: Time.current)
      wrapper.reload

      with_flags(canonical: true, idempotent: true) do
        expect(wrapper.reblog?).to be_falsey
        expect(react(wrapper).status_id).to eq wrapper.id
      end
    end
  end

  describe 'delivery parity for a new reaction' do
    let(:domain) { "author-#{SecureRandom.hex(4)}.example" }
    let(:booster_domain) { "booster-#{SecureRandom.hex(4)}.example" }
    let(:remote_author) do
      Fabricate(:account, domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/inbox", uri: "https://#{domain}/users/author")
    end
    let(:remote_booster) do
      Fabricate(:account, domain: booster_domain, protocol: :activitypub, inbox_url: "https://#{booster_domain}/inbox", uri: "https://#{booster_domain}/users/booster")
    end

    def payloads
      delivery_jobs.map do |job|
        json, account_id, inbox_url = job['args']
        payload = Oj.load(json)
        type = payload['type'] == 'Undo' ? payload.dig('object', 'type') : payload['type']
        {
          type: type,
          account_id: account_id,
          inbox_url: inbox_url,
          object: payload['type'] == 'Undo' ? payload.dig('object', 'object') : payload['object'],
          actor: payload['type'] == 'Undo' ? payload.dig('object', 'actor') : payload['actor'],
        }
      end
    end

    it 'addresses the original author for every flag combination, including a different booster' do
      Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'unicode', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      Node.create!(domain: booster_domain, info: { 'emoji_reaction_type' => 'none', 'favourite' => 'none', 'software_name' => 'mastodon' }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      status = Fabricate(:status, account: remote_author, uri: "https://#{domain}/users/author/statuses/1")
      wrapper = boost_of(status, account: remote_booster)

      seen = {}
      [[false, false], [true, false], [false, true], [true, true]].each do |canonical, idempotent|
        delivery_jobs.clear
        EmojiReaction.where(account: reactor).delete_all
        with_flags(canonical: canonical, idempotent: idempotent) { react(wrapper) }
        seen[[canonical, idempotent]] = payloads
      end

      baseline = seen[[false, false]]
      expect(baseline.map { |row| row.values_at(:type, :account_id, :inbox_url, :object) }).to eq [
        ['EmojiReact', reactor.id, "https://#{domain}/inbox", status.uri],
      ]
      expect(baseline.first[:actor]).to include(reactor.username)
      expect(seen.values.uniq).to eq [baseline]
    end

    it 'keeps Like for a missing Node, kmyblue, and a silenced author, and the legacy undo' do
      status = Fabricate(:status, account: remote_author, uri: "https://#{domain}/users/author/statuses/2")

      [[false, false], [true, true]].each do |canonical, idempotent|
        delivery_jobs.clear
        EmojiReaction.where(account: reactor).delete_all
        with_flags(canonical: canonical, idempotent: idempotent) do
          react(status)
          expect(payloads.map { |row| row[:type] }).to eq ['Like']
          expect { unreact(status, '👍', shortcode_only: true) }.to raise_error(NoMethodError)
        end
      end

      Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'unicode', 'software_name' => 'kmyblue', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      [[false, false], [true, true]].each do |canonical, idempotent|
        delivery_jobs.clear
        EmojiReaction.where(account: reactor).delete_all
        with_flags(canonical: canonical, idempotent: idempotent) do
          react(status)
          expect(payloads.map { |row| [row[:type], row[:inbox_url]] }).to eq [['Like', "https://#{domain}/inbox"]]
          delivery_jobs.clear
          unreact(status, '👍', shortcode_only: true)
          expect(payloads.map { |row| row[:type] }).to eq ['EmojiReact']
        end
      end

      remote_author.update!(silenced_at: Time.now.utc)
      status.account.reload
      [[false, false], [true, true]].each do |canonical, idempotent|
        delivery_jobs.clear
        EmojiReaction.where(account: reactor).delete_all
        with_flags(canonical: canonical, idempotent: idempotent) do
          react(status)
          expect(delivery_jobs).to be_empty
        end
      end
    end
  end

  describe 'authorization is not relaxed' do
    it 'still rejects a projection, and a boost of one only when canonical writes are on' do
      status = Fabricate(:status, account: author, text: 'projection-secret')
      status.update_columns(external_projection: true)
      wrapper = boost_of(status)

      with_flags(canonical: false, idempotent: false) do
        expect { react(status) }.to raise_error(Mastodon::ValidationError)
        expect(react(wrapper).status_id).to eq status.id
      end

      EmojiReaction.where(account: reactor).delete_all
      with_flags(canonical: true, idempotent: true) do
        expect { react(status) }.to raise_error(Mastodon::ValidationError)
        expect { react(wrapper) }.to raise_error(Mastodon::ValidationError)
        expect(reaction_rows).to be_empty
      end
    end
  end

  it 'leaves delivery workers unaware of the write flags' do
    worker_source = Rails.root.join('app/workers/activitypub/delivery_worker.rb').read
    worker_source += Rails.root.join('app/workers/activitypub/custom_emoji_distribution_worker.rb').read

    expect(worker_source).not_to include('EMOJI_REACTION_CANONICAL_WRITES')
    expect(worker_source).not_to include('EMOJI_REACTION_IDEMPOTENT_RETRY')
  end
end
# rubocop:enable Metrics/BlockLength
