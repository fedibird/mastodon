require 'rails_helper'

# Phase 2: the core interaction/rejection services must record moderation
# ledger events via Moderation::EventRecorder. Uses local accounts so no
# federation/network is involved.
RSpec.describe 'Moderation interaction hooks', type: :service do
  let(:alice) { Fabricate(:account, username: 'alice') }
  let(:bob)   { Fabricate(:account, username: 'bob') }

  def last_interaction
    ModerationInteractionEvent.order(:id).last
  end

  def last_rejection
    ModerationRejectionEvent.order(:id).last
  end

  describe FollowService do
    it 'records a follow interaction' do
      expect { FollowService.new.call(alice, bob) }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'follow'
      expect(event.actor_subject.account_id).to eq alice.id
      expect(event.target_subject.account_id).to eq bob.id
    end
  end

  describe FavouriteService do
    it 'records a favourite interaction toward the status author' do
      status = Fabricate(:status, account: bob)

      expect { FavouriteService.new.call(alice, status) }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'favourite'
      expect(event.actor_subject.account_id).to eq alice.id
      expect(event.target_subject.account_id).to eq bob.id
      expect(event.status_id).to eq status.id
    end
  end

  describe ProcessMentionsService do
    it 'records a mention interaction for an explicit mention' do
      status = Fabricate(:status, account: alice, text: "@#{bob.username} hello there")

      expect { ProcessMentionsService.new.call(status) }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'mention'
      expect(event.actor_subject.account_id).to eq alice.id
      expect(event.target_subject.account_id).to eq bob.id
    end

    it 'records a reply when the mention targets the replied-to account' do
      parent = Fabricate(:status, account: bob)
      status = Fabricate(:status, account: alice, thread: parent, text: '@bob replying')

      ProcessMentionsService.new.call(status)

      event = last_interaction
      expect(event.event_type).to eq 'reply'
      expect(event.target_subject.account_id).to eq bob.id
    end
  end

  describe PostStatusService do
    it 'records a quote interaction toward the quoted author' do
      quoted = Fabricate(:status, account: bob)
      # LinkCrawlWorker runs inline in tests and would hit the network; it runs
      # async in production, so stub it out here to exercise the quote hook.
      allow_any_instance_of(LinkCrawlWorker).to receive(:perform)

      expect { PostStatusService.new.call(alice, text: 'nice post', quote_id: quoted.id) }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'quote'
      expect(event.actor_subject.account_id).to eq alice.id
      expect(event.target_subject.account_id).to eq bob.id
    end
  end

  describe BlockService do
    it 'records a block rejection' do
      expect { BlockService.new.call(alice, bob) }.to change(ModerationRejectionEvent, :count).by(1)

      event = last_rejection
      expect(event.event_type).to eq 'block'
      expect(event.rejector_subject.account_id).to eq alice.id
      expect(event.rejected_subject.account_id).to eq bob.id
    end
  end

  describe MuteService do
    it 'records a mute rejection with the notifications flag in metadata' do
      expect { MuteService.new.call(alice, bob, notifications: true) }.to change(ModerationRejectionEvent, :count).by(1)

      event = last_rejection
      expect(event.event_type).to eq 'mute'
      expect(event.rejector_subject.account_id).to eq alice.id
      expect(event.rejected_subject.account_id).to eq bob.id
      expect(event.metadata['hide_notifications']).to be true
    end
  end

  describe ReportService do
    it 'records a report rejection' do
      expect { ReportService.new.call(alice, bob) }.to change(ModerationRejectionEvent, :count).by(1)

      event = last_rejection
      expect(event.event_type).to eq 'report'
      expect(event.rejector_subject.account_id).to eq alice.id
      expect(event.rejected_subject.account_id).to eq bob.id
    end
  end

  describe RejectFollowService do
    it 'records a follow_reject rejection from the rejecting account' do
      bob.request_follow!(alice)

      expect { RejectFollowService.new.call(bob, alice) }.to change(ModerationRejectionEvent, :count).by(1)

      event = last_rejection
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq alice.id
      expect(event.rejected_subject.account_id).to eq bob.id
    end
  end

  describe RemoveFromFollowersService do
    it 'records a remove_follower rejection for each removed follower' do
      bob.follow!(alice)

      expect { RemoveFromFollowersService.new.call(alice, [bob.id]) }.to change(ModerationRejectionEvent, :count).by(1)

      event = last_rejection
      expect(event.event_type).to eq 'remove_follower'
      expect(event.rejector_subject.account_id).to eq alice.id
      expect(event.rejected_subject.account_id).to eq bob.id
    end
  end
end
