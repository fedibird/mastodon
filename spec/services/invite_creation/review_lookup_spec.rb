# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InviteCreation::ReviewLookup do # rubocop:disable Metrics/BlockLength
  let(:user) { user_with_role('Owner') }

  def shell
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'invite_creation' => 'always' }
    )
    Rails.cache.clear
    InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'indexes creation reviews for the given invites in one lookup' do
    held = shell
    other = Fabricate(:invite, user: user, expires_at: nil)
    ignored = ActionReviewRequest.create!(
      operation_type: 'follow_import',
      state: :pending,
      actor_account: user.account,
      resource: FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(user.account),
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      ),
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: {},
      requested_at: Time.now.utc
    )

    index = described_class.for_invites([held.invite, other])

    expect(index.keys).to contain_exactly(held.invite.id)
    expect(index[held.invite.id]).to eq held.request
    expect(index.values).not_to include(ignored)
  end

  it 'does not expire a pending shell into a usable code or change the review' do
    held = shell
    expires_at = held.invite.expires_at

    described_class.management_expire!(held.invite)

    fresh = held.invite.reload
    expect(fresh.expires_at.to_i).to eq expires_at.to_i
    expect(fresh.valid_for_use?).to be false
    expect(held.request.reload.pending_state?).to be true
  end

  it 'treats a cancelled creation review as held and leaves the shell expired' do
    held = shell
    expires_at = held.invite.expires_at
    held.request.update!(state: :cancelled)

    expect(described_class.held_review?(held.request.reload)).to be true

    described_class.management_expire!(held.invite)

    fresh = held.invite.reload
    expect(fresh.expires_at.to_i).to eq expires_at.to_i
    expect(fresh.valid_for_use?).to be false
    expect(held.request.reload.cancelled_state?).to be true
  end

  it 'still expires an invite whose creation review is approved' do
    held = shell
    ActionReview::DecisionService.new.call(
      request: held.request,
      decision: 'approve',
      reviewer_account: user.account,
      decision_note: nil
    )
    expect(described_class.held_review?(held.request.reload)).to be false

    described_class.management_expire!(held.invite)

    expect(held.invite.reload).to be_expired
    expect(held.request.reload.approved_state?).to be true
  end
end
