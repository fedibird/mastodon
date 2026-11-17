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
