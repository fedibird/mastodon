# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InviteFilter do
  let(:user) { Fabricate(:user, admin: true) }

  def hold(mode_expires: 1800)
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'invite_creation' => 'always' }
    )
    Rails.cache.clear
    InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: mode_expires })
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'returns only pending or rejected creation reviews for the review filters' do
    pending = hold.invite
    rejected = hold.invite
    ActionReview::DecisionService.new.call(
      request: ActionReviewRequest.find_by!(resource: rejected),
      decision: 'reject',
      reviewer_account: user.account,
      decision_note: nil
    )
    available = Fabricate(:invite, user: user, expires_at: nil)
    expired = Fabricate(:invite, user: user, expires_at: 1.hour.ago)

    expect(described_class.new(review_pending: '1').results).to contain_exactly(pending)
    expect(described_class.new(review_rejected: '1').results).to contain_exactly(rejected)
    expect(described_class.new(available: '1').results).to contain_exactly(available)
    expect(described_class.new(expired: '1').results).to include(expired, pending, rejected)
    expect(described_class.new(expired: '1').results).not_to include(available)
  end
end
