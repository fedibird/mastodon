# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::Adapters::InviteCreation do # rubocop:disable Metrics/BlockLength
  let(:reviewer) { user_with_role('Owner').account }
  let(:user) { user_with_role('Owner') }

  def store_always
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'invite_creation' => 'always' }
    )
    Rails.cache.clear
  end

  def hold(expires_in: 3600, max_uses: 4)
    store_always
    InviteCreation::CreateService.new.call(
      user: user,
      attributes: { max_uses: max_uses, expires_in: expires_in, autofollow: true, comment: 'kept-on-invite' }
    )
  end

  def decide(request, verb, note: ' noted ', reviewer_account: reviewer)
    ActionReview::DecisionService.new.call(
      request: request,
      decision: verb,
      reviewer_account: reviewer_account,
      decision_note: note
    )
  end

  around do |example|
    example.run
  ensure
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'is registered for invite creation decisions' do
    expect(ActionReview::AdapterRegistry.fetch!('invite_creation')).to eq described_class
    expect(ActionReview::AdapterRegistry.registered?('invite_creation')).to be true
  end

  it 'approves a pending shell from the approval instant and creates no moderation action' do
    created = travel_to(Time.utc(2026, 9, 22, 8, 0, 0)) { hold(expires_in: 3600) }
    invite = created.invite
    request = created.request

    expect do
      travel_to(Time.utc(2026, 9, 22, 10, 0, 0)) { decide(request, 'approve', note: '  ship  ') }
    end.not_to change(ModerationAction, :count)

    invite.reload
    request.reload
    expect(request.approved_state?).to be true
    expect(request.reviewer_account).to eq reviewer
    expect(request.reviewed_at).to be_within(1.second).of(Time.utc(2026, 9, 22, 10, 0, 0))
    expect(request.decision_note).to eq 'ship'
    expect(invite.expires_at).to be_within(1.second).of(Time.utc(2026, 9, 22, 11, 0, 0))
    expect(invite.max_uses).to eq 4
    expect(invite.autofollow).to be true
    expect(invite.comment).to eq 'kept-on-invite'
    expect(invite.uses).to eq 0
    travel_to(Time.utc(2026, 9, 22, 10, 30, 0)) do
      expect(invite.valid_for_use?).to be true
    end
  end

  it 'restores a nil expiration when the request had no lifetime' do
    created = hold(expires_in: '')
    decide(created.request, 'approve', note: nil)

    expect(created.invite.reload.expires_at).to be_nil
    expect(created.invite.valid_for_use?).to be true
  end

  it 'rejects a pending shell and leaves it unusable without a moderation action' do
    created = hold
    expect { decide(created.request, 'reject', note: 'no') }.not_to change(ModerationAction, :count)

    expect(created.request.reload.rejected_state?).to be true
    expect(created.request.decision_note).to eq 'no'
    expect(created.request.reviewer_account).to eq reviewer
    expect(created.invite.reload.expired?).to be true
    expect(created.invite.valid_for_use?).to be false
    expect(Invite.exists?(created.invite.id)).to be true
  end

  it 'fails closed for a mismatched actor, a missing invite, a used shell, or a usable shell' do
    mismatched = hold
    mismatched.request.update!(actor_account: Fabricate(:account))
    expect { decide(mismatched.request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(mismatched.request.reload.pending_state?).to be true
    expect(mismatched.invite.reload.valid_for_use?).to be false

    missing = hold
    missing.invite.delete
    expect { decide(missing.request.reload, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(missing.request.reload.pending_state?).to be true

    used = hold
    Invite.where(id: used.invite.id).update_all(uses: 1)
    used.invite.reload
    expect { decide(used.request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(used.request.reload.pending_state?).to be true

    usable = hold
    usable.invite.update_columns(expires_at: 1.hour.from_now)
    expect { decide(usable.request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(usable.request.reload.pending_state?).to be true
    expect(usable.invite.reload.expires_at).to be > Time.now.utc
  end

  it 'does not extend or revive an approved invite on a repeated approve' do
    created = travel_to(Time.utc(2026, 9, 22, 8, 0, 0)) { hold(expires_in: 60) }
    travel_to(Time.utc(2026, 9, 22, 8, 1, 0)) { decide(created.request, 'approve', note: 'once') }
    reviewed_at = created.request.reload.reviewed_at
    expires_at = created.invite.reload.expires_at
    travel_to(Time.utc(2026, 9, 22, 10, 0, 0)) do
      expect(created.invite.reload.valid_for_use?).to be false
      expect(decide(created.request, 'approve', note: 'twice')).to eq :already_approved
      expect(created.invite.reload.expires_at.to_i).to eq expires_at.to_i
      expect(created.invite.valid_for_use?).to be false
    end

    expect(created.request.reload.decision_note).to eq 'once'
    expect(created.request.reviewed_at.to_i).to eq reviewed_at.to_i
  end

  it 'does not mutate a rejected invite on a repeated reject' do
    created = hold
    decide(created.request, 'reject', note: 'once')
    expires_at = created.invite.reload.expires_at

    expect(decide(created.request, 'reject', note: 'twice')).to eq :already_rejected

    expect(created.request.reload.decision_note).to eq 'once'
    expect(created.invite.reload.expires_at.to_i).to eq expires_at.to_i
    expect(created.invite.valid_for_use?).to be false
  end

  it 'refuses the opposite decision after either terminal state' do
    approved = hold
    decide(approved.request, 'approve')
    expect { decide(approved.request, 'reject') }.to raise_error(ActionReview::DecisionError)
    expect(approved.request.reload.approved_state?).to be true

    rejected = hold
    decide(rejected.request, 'reject')
    expect { decide(rejected.request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(rejected.request.reload.rejected_state?).to be true
    expect(rejected.invite.reload.valid_for_use?).to be false
  end

  it 'keeps an approved code unusable when the issuing user is no longer functional' do
    created = hold(expires_in: '')
    decide(created.request, 'approve')
    created.invite.user.account.suspend!

    expect(created.invite.reload.expires_at).to be_nil
    expect(created.invite.valid_for_use?).to be false
  end

  describe 'concurrent moderators' do
    self.use_transactional_tests = false

    after do
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
      ActionReviewRequest.where(operation_type: 'invite_creation').delete_all
      Invite.where(user_id: user.id).delete_all
    end

    it 'lets exactly one terminal decision win' do
      created = hold(expires_in: '')
      other = user_with_role('Moderator').account
      start = Queue.new
      winners = Queue.new
      errors = Queue.new

      threads = [
        [reviewer.id, 'approve'],
        [other.id, 'reject'],
      ].map do |actor_id, verb|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            fresh = ActionReviewRequest.find(created.request.id)
            actor = Account.find(actor_id)
            decide(fresh, verb, note: verb, reviewer_account: actor)
            winners << verb
          rescue ActionReview::DecisionError
            errors << verb
          rescue StandardError => e
            errors << "#{verb}:#{e.class}:#{e.message}"
          end
        end
      end

      2.times { start << true }
      threads.each { |thread| thread.join(10) }

      expect(threads.all?(&:stop?)).to be true
      expect(winners.size).to eq 1
      expect(errors.size).to eq 1
      request = created.request.reload
      invite = created.invite.reload
      expect(request.pending_state?).to be false
      if request.approved_state?
        expect(invite.expires_at).to be_nil
        expect(invite.valid_for_use?).to be true
      else
        expect(request.rejected_state?).to be true
        expect(invite.valid_for_use?).to be false
      end
    end
  end
end
