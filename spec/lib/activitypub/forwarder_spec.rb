# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::Forwarder do # rubocop:disable Metrics/BlockLength
  let(:sender) do
    Fabricate(
      :account,
      protocol: :activitypub,
      domain: 'remote.example',
      inbox_url: 'https://remote.example/users/actor/inbox',
      shared_inbox_url: 'https://remote.example/inbox',
      uri: 'https://remote.example/users/actor'
    )
  end
  let(:status) { Fabricate(:status, visibility: :public) }
  let(:json) { { 'id' => 'https://remote.example/activities/1', 'signature' => { 'type' => 'RsaSignature2017' } } }

  describe '#forwardable?' do
    it 'requires a signature and a distributable status' do
      expect(described_class.new(sender, json, status).forwardable?).to be true
      expect(described_class.new(sender, json, Fabricate(:status, visibility: :unlisted)).forwardable?).to be true
      expect(described_class.new(sender, { 'id' => json['id'] }, status).forwardable?).to be false
      expect(described_class.new(sender, json, Fabricate(:status, visibility: :private)).forwardable?).to be false
      expect(described_class.new(sender, json, Fabricate(:status, visibility: :direct)).forwardable?).to be false
    end
  end

  describe 'inbox selection' do
    it 'addresses followers of local rebloggers and omits the sender inbox' do
      booster = Fabricate(:account)
      follower = Fabricate(:account, protocol: :activitypub, domain: 'follower.example', username: 'fan', inbox_url: 'https://follower.example/users/fan/inbox')
      Fabricate(:status, account: booster, reblog: status, visibility: :public)
      follower.follow!(booster)

      forwarder = described_class.new(sender, json, status)

      expect(forwarder.send(:inboxes)).to include('https://follower.example/users/fan/inbox')
      expect(forwarder.send(:inboxes)).not_to include(sender.preferred_inbox_url)
      expect(forwarder.send(:signature_account_id)).to eq booster.id
    end

    it 'also addresses followers of the local account being replied to' do
      author = Fabricate(:account)
      parent = Fabricate(:status, account: author, visibility: :public)
      reply = Fabricate(:status, visibility: :public, thread: parent, account: Fabricate(:account, domain: 'other.example', protocol: :activitypub, username: 'replier'))
      follower = Fabricate(:account, protocol: :activitypub, domain: 'parent-follower.example', username: 'reader', inbox_url: 'https://parent-follower.example/users/reader/inbox')
      follower.follow!(author)

      forwarder = described_class.new(sender, json, reply)

      expect(forwarder.send(:inboxes)).to include('https://parent-follower.example/users/reader/inbox')
      expect(forwarder.send(:signature_account_id)).to eq author.id
    end
  end

  describe '#forward!' do
    it 'delivers the original JSON through the low-priority worker' do
      booster = Fabricate(:account)
      follower = Fabricate(:account, protocol: :activitypub, domain: 'delivery.example', username: 'fan', inbox_url: 'https://delivery.example/users/fan/inbox')
      Fabricate(:status, account: booster, reblog: status, visibility: :public)
      follower.follow!(booster)
      jobs = []
      allow(ActivityPub::LowPriorityDeliveryWorker).to receive(:push_bulk) do |inboxes, options, &block|
        expect(options).to eq(limit: 1_000)
        inboxes.each { |inbox| jobs << block.call(inbox) }
      end

      described_class.new(sender, json, status).forward!

      expect(jobs.map(&:last)).to include('https://delivery.example/users/fan/inbox')
      delivered = jobs.find { |job| job.last == 'https://delivery.example/users/fan/inbox' }
      expect(Oj.load(delivered.first)).to eq json
      expect(delivered[1]).to eq booster.id
    end
  end
end
