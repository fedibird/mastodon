# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InviteCreation::CreateService do # rubocop:disable Metrics/BlockLength
  subject(:service) { described_class.new }

  let(:user) { user_with_role('Owner') }

  def store_policy(mode)
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'invite_creation' => mode }
    )
    Rails.cache.clear
  end

  around do |example|
    example.run
  ensure
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'issues a normal invite and no review when policy is off' do
    store_policy('off')

    result = service.call(user: user, attributes: { max_uses: 10, expires_in: 1800, autofollow: true, comment: 'bring a friend' })

    expect(result.issued?).to be true
    expect(result.request).to be_nil
    expect(ActionReviewRequest.count).to eq 0
    invite = result.invite.reload
    expect(invite.max_uses).to eq 10
    expect(invite.autofollow).to be true
    expect(invite.comment).to eq 'bring a friend'
    expect(invite.expires_at).to be_within(5.seconds).of(Time.now.utc + 1800)
    expect(invite.valid_for_use?).to be true
    expect(Invite.available).to include(invite)
  end

  it 'creates an expired shell and a pending review when policy is always' do
    store_policy('always')

    result = service.call(user: user, attributes: { max_uses: 10, expires_in: 86_400, autofollow: false, comment: 'secret-comment-text' })
    invite = result.invite.reload
    request = result.request

    expect(result.pending_review?).to be true
    expect(invite.expired?).to be true
    expect(invite.valid_for_use?).to be false
    expect(Invite.available).not_to include(invite)
    expect(invite.max_uses).to eq 10
    expect(invite.autofollow).to be false
    expect(invite.comment).to eq 'secret-comment-text'
    expect(invite.uses).to eq 0
    expect(request.pending_state?).to be true
    expect(request.operation_type).to eq 'invite_creation'
    expect(request.resource).to eq invite
    expect(request.actor_account).to eq user.account
    expect(request.signal_level).to eq 'none'
    expect(request.evidence.keys).to match_array(
      %w(schema_version requested_max_uses requested_expires_in_seconds autofollow comment_present)
    )
    expect(request.evidence['schema_version']).to eq 1
    expect(request.evidence['requested_max_uses']).to eq 10
    expect(request.evidence['requested_expires_in_seconds']).to eq 86_400
    expect(request.evidence['autofollow']).to be false
    expect(request.evidence['comment_present']).to be true
    expect(request.evidence.to_json).not_to include(invite.code)
    expect(request.evidence.to_json).not_to include('secret-comment-text')
    expect(request.evidence.to_json).not_to include('invite_code')
  end

  it 'stores a null duration when no expiration was requested' do
    store_policy('always')

    result = service.call(user: user, attributes: { max_uses: nil, expires_in: '' })

    expect(result.request.evidence['requested_expires_in_seconds']).to be_nil
    expect(result.request.evidence['requested_max_uses']).to be_nil
    expect(result.invite.reload.expired?).to be true
  end

  it 'creates neither an invite nor a review when validation fails' do
    store_policy('always')

    result = service.call(user: user, attributes: { comment: 'x' * 421, expires_in: 1800 })

    expect(result.invalid?).to be true
    expect(result.invite).not_to be_persisted
    expect(result.invite.errors[:comment]).to be_present
    expect(Invite.count).to eq 0
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'rolls back the shell when the review row cannot be saved' do
    store_policy('always')
    allow_any_instance_of(ActionReview::RequestService).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'review write failed')

    expect do
      service.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
    end.to raise_error(ActiveRecord::StatementInvalid, 'review write failed')

    expect(Invite.count).to eq 0
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'holds the shell when a malformed invite policy falls back to always' do
    store_policy('medium')

    result = service.call(user: user, attributes: { max_uses: 2, expires_in: 3600 })

    expect(result.pending_review?).to be true
    expect(result.invite.reload.valid_for_use?).to be false
    expect(result.request.policy_mode).to eq 'always'
    expect(result.request.evidence['requested_expires_in_seconds']).to eq 3600
  end
end
