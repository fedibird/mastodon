# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationRequests::RejectService do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    example.run
  ensure
    Setting.group_creation_requests = previous
  end

  let(:requester) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }

  def submit
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'rejectme',
      display_name: 'Reject Me',
      note: 'Please no'
    )
  end

  def reject(request, note: 'Not a good fit', reviewer_account: reviewer.account)
    described_class.call(request: request, reviewer_account: reviewer_account, decision_note: note)
  end

  it 'rejects with a trimmed reason and does not create a group' do
    request = submit
    result = reject(request, note: '  duplicate of an existing group  ')

    expect(result.code).to eq :rejected
    expect(request.reload).to be_rejected
    expect(request.decision_note).to eq 'duplicate of an existing group'
    expect(request.decision).to be_rejected
    expect(request.decision.decision_note).to eq request.decision_note
    expect(Account.where(username: 'rejectme')).to be_empty
    expect(ManagedGroup.count).to eq 0
  end

  it 'refuses a blank reason, a moderator, and a second decision' do
    request = submit
    expect(reject(request, note: '   ').code).to eq :decision_note_blank
    expect(request.reload).to be_pending

    moderator = user_with_role('Moderator')
    expect(reject(request, reviewer_account: moderator.account).code).to eq :not_authorized
    expect(request.reload).to be_pending

    expect(reject(request).code).to eq :rejected
    expect(reject(request.reload, note: 'again').code).to eq :not_pending
    expect(GroupCreationDecision.count).to eq 1
    expect(Account.where(username: 'rejectme')).to be_empty
  end

  it 'does nothing while the feature flag is off' do
    request = submit
    Setting.group_creation_requests = false

    expect(reject(request).code).to eq :feature_disabled
    expect(request.reload).to be_pending
  end
end
