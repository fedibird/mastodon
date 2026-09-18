require 'rails_helper'

RSpec.describe FollowService, type: :service do
  let(:sender) { Fabricate(:account, username: 'alice') }

  subject { FollowService.new }

  context 'local account' do
    describe 'locked account' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, locked: true, username: 'bob')).account }

      before do
        subject.call(sender, bob)
      end

      it 'creates a follow request with reblogs' do
        expect(FollowRequest.find_by(account: sender, target_account: bob, show_reblogs: true)).to_not be_nil
      end
    end

    describe 'locked account, no reblogs' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, locked: true, username: 'bob')).account }

      before do
        subject.call(sender, bob, reblogs: false)
      end

      it 'creates a follow request without reblogs' do
        expect(FollowRequest.find_by(account: sender, target_account: bob, show_reblogs: false)).to_not be_nil
      end
    end

    describe 'unlocked account, from silenced account' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        sender.touch(:silenced_at)
        subject.call(sender, bob)
      end

      it 'creates a follow request with reblogs' do
        expect(FollowRequest.find_by(account: sender, target_account: bob, show_reblogs: true)).to_not be_nil
      end
    end

    describe 'unlocked account, from a muted account' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        bob.mute!(sender)
        subject.call(sender, bob)
      end

      it 'creates a following relation with reblogs' do
        expect(sender.following?(bob)).to be true
        expect(sender.muting_reblogs?(bob)).to be false
      end
    end

    describe 'unlocked account' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        subject.call(sender, bob)
      end

      it 'creates a following relation with reblogs' do
        expect(sender.following?(bob)).to be true
        expect(sender.muting_reblogs?(bob)).to be false
      end
    end

    describe 'unlocked account, no reblogs' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        subject.call(sender, bob, reblogs: false)
      end

      it 'creates a following relation without reblogs' do
        expect(sender.following?(bob)).to be true
        expect(sender.muting_reblogs?(bob)).to be true
      end
    end

    describe 'already followed account' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        sender.follow!(bob)
        subject.call(sender, bob)
      end

      it 'keeps a following relation' do
        expect(sender.following?(bob)).to be true
      end
    end

    describe 'already followed account, turning reblogs off' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        sender.follow!(bob, reblogs: true)
        subject.call(sender, bob, reblogs: false)
      end

      it 'disables reblogs' do
        expect(sender.muting_reblogs?(bob)).to be true
      end
    end

    describe 'already followed account, turning reblogs on' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        sender.follow!(bob, reblogs: false)
        subject.call(sender, bob, reblogs: true)
      end

      it 'disables reblogs' do
        expect(sender.muting_reblogs?(bob)).to be false
      end
    end

    describe 'languages on a new follow' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      it 'stores languages on the follow' do
        subject.call(sender, bob, languages: %w(en ja))
        expect(Follow.find_by(account: sender, target_account: bob).languages).to match_array %w(en ja)
      end
    end

    describe 'updating languages on an existing follow' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

      before do
        sender.follow!(bob, languages: %w(en))
      end

      it 'updates languages when a new list is given' do
        subject.call(sender, bob, languages: %w(ja))
        expect(Follow.find_by(account: sender, target_account: bob).languages).to eq %w(ja)
      end

      it 'keeps languages when the option is omitted' do
        subject.call(sender, bob, notify: true)
        expect(Follow.find_by(account: sender, target_account: bob).languages).to eq %w(en)
      end

      it 'clears the restriction when an empty array is given' do
        subject.call(sender, bob, languages: [])
        expect(Follow.find_by(account: sender, target_account: bob).languages).to eq []
      end
    end

    describe 'languages on a pending follow request' do
      let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, locked: true, username: 'bob')).account }

      it 'stores languages on the follow request' do
        subject.call(sender, bob, languages: %w(en ja))
        expect(FollowRequest.find_by(account: sender, target_account: bob).languages).to match_array %w(en ja)
      end
    end
  end

  context 'remote ActivityPub account' do
    let(:bob) { Fabricate(:user, account: Fabricate(:account, username: 'bob', domain: 'example.com', protocol: :activitypub, inbox_url: 'http://example.com/inbox')).account }

    before do
      stub_request(:post, "http://example.com/inbox").to_return(:status => 200, :body => "", :headers => {})
      subject.call(sender, bob)
    end

    it 'creates follow request' do
      expect(FollowRequest.find_by(account: sender, target_account: bob)).to_not be_nil
    end

    it 'sends a follow activity to the inbox' do
      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
    end
  end
end
