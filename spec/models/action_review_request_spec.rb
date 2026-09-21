# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReviewRequest do # rubocop:disable Metrics/BlockLength
  let(:actor) { Fabricate(:account) }
  let(:resource) { Fabricate(:account) }

  def build_request(**attrs)
    described_class.new(
      {
        operation_type: 'follow_import',
        state: :pending,
        actor_account: actor,
        resource: resource,
        trigger: 'policy',
        signal_level: 'none',
        policy_mode: 'always',
        policy_version: 'action-review-policy-v1',
        reason_codes: ['policy_always'],
        evidence: { 'schema' => 1 },
        requested_at: Time.now.utc,
      }.merge(attrs)
    )
  end

  it 'accepts a pending request with a factual snapshot and optional reviewer fields' do
    request = build_request
    expect(request).to be_valid
    expect(request.reviewer_account).to be_nil
    expect(request.reviewed_at).to be_nil
    request.save!
    expect(request.pending_state?).to be true
    expect(request.resource).to eq resource
  end

  it 'rejects an unregistered operation' do
    request = build_request(operation_type: 'moderation_suspend')
    expect(request).not_to be_valid
    expect(request.errors[:operation_type]).to be_present
  end

  it 'rejects an invalid signal_level' do
    expect(build_request(signal_level: 'critical')).not_to be_valid
  end

  it 'rejects an invalid policy_mode' do
    expect(build_request(policy_mode: 'dangerous')).not_to be_valid
  end

  it 'requires evidence to be an object' do
    request = build_request
    request.evidence = ['not-a-hash']
    expect(request).not_to be_valid
    expect(request.errors[:evidence]).to be_present
  end

  it 'requires reason_codes to be an array' do
    request = build_request
    request.reason_codes = { 'code' => 'policy_always' }
    expect(request).not_to be_valid
    expect(request.errors[:reason_codes]).to be_present
  end

  it 'allows a nil actor and reviewer' do
    request = build_request(actor_account: nil, reviewer_account: nil)
    expect(request).to be_valid
    request.save!
    expect(request.actor_account_id).to be_nil
  end

  it 'keeps the snapshot after the actor account row is deleted' do
    request = build_request
    request.save!
    actor.delete
    reloaded = described_class.find(request.id)
    expect(reloaded.actor_account_id).to be_nil
    expect(reloaded.operation_type).to eq 'follow_import'
    expect(reloaded.resource_id).to eq resource.id
  end

  it 'resolves the polymorphic resource while it exists' do
    request = build_request
    request.save!
    expect(request.reload.resource).to eq resource
    expect(request.resource_type).to eq 'Account'
  end

  it 'prevents a second pending request for the same operation and resource' do
    build_request.save!
    duplicate = build_request
    expect(duplicate).not_to be_valid
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows a later pending request after the previous one is no longer pending' do
    first = build_request
    first.save!
    first.update!(state: :approved, reviewed_at: Time.now.utc, reviewer_account: actor)
    second = build_request
    expect(second).to be_valid
    second.save!
    expect(described_class.where(resource: resource).count).to eq 2
  end
end
