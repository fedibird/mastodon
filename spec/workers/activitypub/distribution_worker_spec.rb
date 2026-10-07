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
