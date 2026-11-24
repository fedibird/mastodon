# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::Activity::Announce do
  let(:sender) { Fabricate(:account, followers_url: 'http://example.com/followers', uri: 'https://example.com/actor', domain: 'example.com') }
  let(:status) { Fabricate(:status) }
  let(:object_uri) { ActivityPub::TagManager.instance.uri_for(status) }

  before do
    Fabricate(:account).follow!(sender)
  end

  def announce(id, published)
    described_class.new({
      id: id,
      type: 'Announce',
      actor: sender.uri,
      published: published,
      object: object_uri,
      to: sender.followers_url,
    }.with_indifferent_access, sender).perform
  end

  it 'keeps one boost and ignores a redelivery of the same Announce id' do
    first = announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    created = first.created_at

    again = announce('https://example.com/announce/a', 1.minute.ago.iso8601)

    expect(again.id).to eq first.id
    expect(again.reload.created_at).to eq created
    expect(sender.statuses.where(reblog_of_id: status.id).count).to eq 1
  end

  it 'replaces the boost when a newer Announce id arrives after the cooldown' do
    first = announce('https://example.com/announce/a', 10.minutes.ago.iso8601)

    travel 301.seconds do
      second = announce('https://example.com/announce/b', Time.current.iso8601)

      expect(second.id).not_to eq first.id
      expect(second.uri).to eq 'https://example.com/announce/b'
      expect(Status.find_by(id: first.id)).to be_nil
      expect(sender.statuses.where(reblog_of_id: status.id).count).to eq 1
      expect(status.reload.reblogs_count).to eq 1
    end
  end

  it 'holds a newer id during the cooldown and applies it later' do
    announce('https://example.com/announce/a', 1.minute.ago.iso8601)
    announce('https://example.com/announce/b', Time.current.iso8601)

    expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/a'
    hold = RemoteReboostHold.find_by(account: sender, reblog_of: status)
    expect(hold.activity_uri).to eq 'https://example.com/announce/b'

    announce('https://example.com/announce/a', 1.minute.ago.iso8601)
    expect(hold.reload.activity_uri).to eq 'https://example.com/announce/b'

    travel 301.seconds do
      Reboost::RemoteApplyWorker.new.perform(hold.id)
      expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/b'
      expect(RemoteReboostHold.find_by(id: hold.id)).to be_nil
    end
  end

  # A real Misskey server was not used. An Announce with the same timestamp,
  # or with published omitted, stays superseded here and is not measured remotely.
  it 'keeps the current boost when another id has the same or a missing published time' do
    published = 10.minutes.ago.iso8601
    first = announce('https://example.com/announce/a', published)

    travel 301.seconds do
      announce('https://example.com/announce/b', published)
      described_class.new({
        id: 'https://example.com/announce/c',
        type: 'Announce',
        actor: sender.uri,
        object: object_uri,
        to: sender.followers_url,
      }.with_indifferent_access, sender).perform

      expect(sender.statuses.find_by(reblog_of_id: status.id).id).to eq first.id
      expect(ReboostAnnounceState.superseded?(sender.id, 'https://example.com/announce/b')).to be true
      expect(ReboostAnnounceState.superseded?(sender.id, 'https://example.com/announce/c')).to be true
    end
  end

  it 'does not let a delayed older Announce roll back a newer one' do
    announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    travel 301.seconds do
      newer = announce('https://example.com/announce/b', Time.current.iso8601)
      announce('https://example.com/announce/a', 20.minutes.ago.iso8601)

      expect(sender.statuses.find_by(reblog_of_id: status.id).id).to eq newer.id
      expect(ReboostAnnounceState.superseded?(sender.id, 'https://example.com/announce/a')).to be true
    end
  end

  it 'removes only the Announce id named by Undo' do
    announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    travel 301.seconds do
      newer = announce('https://example.com/announce/b', Time.current.iso8601)
      ActivityPub::Activity::Undo.new({
        id: 'https://example.com/undo/a',
        type: 'Undo',
        actor: sender.uri,
        object: { id: 'https://example.com/announce/a', type: 'Announce', object: object_uri },
      }.with_indifferent_access, sender).perform

      expect(sender.statuses.find_by(reblog_of_id: status.id).id).to eq newer.id

      ActivityPub::Activity::Undo.new({
        id: 'https://example.com/undo/b',
        type: 'Undo',
        actor: sender.uri,
        object: { id: 'https://example.com/announce/b', type: 'Announce', object: object_uri },
      }.with_indifferent_access, sender).perform

      expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty
      expect(announce('https://example.com/announce/b', Time.current.iso8601)).to be_nil
    end
  end

  it 'locks Announce and an id-reference Undo on the original status' do
    keys = []
    allow(RedisLock).to receive(:acquire).and_wrap_original do |method, **kwargs, &block|
      keys << kwargs[:key]
      method.call(**kwargs, &block)
    end

    announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    ActivityPub::Activity::Undo.new({
      id: 'https://example.com/undo/a',
      type: 'Undo',
      actor: sender.uri,
      object: 'https://example.com/announce/a',
    }.with_indifferent_access, sender).perform

    key = "lock:#{Reboost::AnnounceLock.key(sender.id, status.id)}"
    expect(keys.count(key)).to be >= 2
    expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty
  end

  it 'cancels a held Announce when Undo names only its id' do
    announce('https://example.com/announce/a', 1.minute.ago.iso8601)
    announce('https://example.com/announce/b', Time.current.iso8601)
    ActivityPub::Activity::Undo.new({
      id: 'https://example.com/undo/b',
      type: 'Undo',
      actor: sender.uri,
      object: 'https://example.com/announce/b',
    }.with_indifferent_access, sender).perform

    expect(RemoteReboostHold.where(account: sender, reblog_of: status)).to be_empty
    expect(ReboostAnnounceState.superseded?(sender.id, 'https://example.com/announce/b')).to be true

    travel 301.seconds do
      expect(announce('https://example.com/announce/b', Time.current.iso8601)).to be_nil
      expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/a'
    end
  end

  it 'finishes a discarded boost before accepting a newer Announce' do
    first = announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    first.discard

    travel 301.seconds do
      second = announce('https://example.com/announce/b', Time.current.iso8601)

      expect(second.uri).to eq 'https://example.com/announce/b'
      expect(Status.unscoped.find_by(id: first.id)).to be_nil
      expect(sender.statuses.where(reblog_of_id: status.id).count).to eq 1
      expect(status.reload.reblogs_count).to eq 1
    end
  end

  it 'holds the newer Announce while removal of the discarded boost is locked' do
    first = announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    first.discard
    blocked = true
    allow(Reboost::RemoteApplyWorker).to receive(:perform_at)
    allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
      raise Mastodon::RaceConditionError if blocked

      method.call(*args, **kwargs)
    end

    travel 301.seconds do
      expect(announce('https://example.com/announce/b', Time.current.iso8601)).to be_nil
      hold = RemoteReboostHold.find_by(account: sender, reblog_of: status)
      expect(hold.activity_uri).to eq 'https://example.com/announce/b'
      expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty

      blocked = false
      Reboost::RemoteApplyWorker.new.perform(hold.id)

      expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/b'
      expect(Status.unscoped.find_by(id: first.id)).to be_nil
      expect(status.reload.reblogs_count).to eq 1
    end
  end

  it 'holds a new Announce id after Undo until the cooldown from the removed boost ends' do
    announce('https://example.com/announce/a', Time.current.iso8601)
    ActivityPub::Activity::Undo.new({
      id: 'https://example.com/undo/a',
      type: 'Undo',
      actor: sender.uri,
      object: { id: 'https://example.com/announce/a', type: 'Announce', object: object_uri },
    }.with_indifferent_access, sender).perform

    expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty

    hold = nil
    travel 60.seconds do
      expect(announce('https://example.com/announce/b', Time.current.iso8601)).to be_nil
      hold = RemoteReboostHold.find_by(account: sender, reblog_of: status)
      expect(hold.activity_uri).to eq 'https://example.com/announce/b'
      expect(hold.available_at).to be_within(5.seconds).of(240.seconds.from_now)
      expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty
    end

    travel 301.seconds do
      Reboost::RemoteApplyWorker.new.perform(hold.id)
      expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/b'
    end
  end

  it 'does not apply a held Announce after Undo removes that id' do
    announce('https://example.com/announce/a', Time.current.iso8601)
    ActivityPub::Activity::Undo.new({
      id: 'https://example.com/undo/a',
      type: 'Undo',
      actor: sender.uri,
      object: { id: 'https://example.com/announce/a', type: 'Announce', object: object_uri },
    }.with_indifferent_access, sender).perform

    hold_id = nil
    travel 60.seconds do
      announce('https://example.com/announce/b', Time.current.iso8601)
      hold = RemoteReboostHold.find_by(account: sender, reblog_of: status)
      hold_id = hold.id
      ActivityPub::Activity::Undo.new({
        id: 'https://example.com/undo/b',
        type: 'Undo',
        actor: sender.uri,
        object: 'https://example.com/announce/b',
      }.with_indifferent_access, sender).perform

      expect(RemoteReboostHold.find_by(id: hold_id)).to be_nil
    end

    travel 361.seconds do
      Reboost::RemoteApplyWorker.new.perform(hold_id)
      expect(sender.statuses.where(reblog_of_id: status.id)).to be_empty
    end
  end

  it 'applies the hold payload that is current inside the lock' do
    announce('https://example.com/announce/a', 1.minute.ago.iso8601)
    announce('https://example.com/announce/b', Time.current.iso8601)
    hold = RemoteReboostHold.find_by(account: sender, reblog_of: status)
    published = Time.current
    hold.update!(
      activity_uri: 'https://example.com/announce/c',
      published_at: published,
      payload: {
        id: 'https://example.com/announce/c',
        type: 'Announce',
        actor: sender.uri,
        published: published.iso8601,
        object: object_uri,
        to: sender.followers_url,
      }
    )

    travel 301.seconds do
      Reboost::RemoteApplyWorker.new.perform(hold.id)
      expect(sender.statuses.where(reblog_of_id: status.id).pick(:uri)).to eq 'https://example.com/announce/c'
      expect(RemoteReboostHold.find_by(id: hold.id)).to be_nil
    end
  end

  it 'keeps another actor independent and does not consult enable_reboost' do
    other = Fabricate(:account, uri: 'https://other.example/actor', domain: 'other.example', followers_url: 'http://other.example/followers')
    Fabricate(:account).follow!(other)
    announce('https://example.com/announce/a', 10.minutes.ago.iso8601)
    described_class.new({
      id: 'https://other.example/announce/a',
      type: 'Announce',
      actor: other.uri,
      published: Time.current.iso8601,
      object: object_uri,
      to: other.followers_url,
    }.with_indifferent_access, other).perform

    expect(sender.statuses.where(reblog_of_id: status.id).count).to eq 1
    expect(other.statuses.where(reblog_of_id: status.id).count).to eq 1
    expect(sender.user).to be_nil
  end
end
