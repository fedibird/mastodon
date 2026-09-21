# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::RequestService do # rubocop:disable Metrics/BlockLength
  subject(:service) { described_class.new }

  let(:actor) { Fabricate(:account) }
  let(:resource) { Fabricate(:account) }
  let(:review_decision) do
    ActionReview::PolicyDecisionService.new.call(
      operation_type: 'invite_creation',
      signal_level: 'none',
      policy_mode: 'always'
    )
  end
  let(:skip_decision) do
    ActionReview::PolicyDecisionService.new.call(
      operation_type: 'invite_creation',
      signal_level: 'none',
      policy_mode: 'off'
    )
  end

  def call_with(decision, evidence: { 'note' => 'factual' }, evaluator_version: 'eval-v1')
    service.call(
      operation_type: 'invite_creation',
      actor_account: actor,
      resource: resource,
      decision: decision,
      evaluator_version: evaluator_version,
      evidence: evidence
    )
  end

  it 'creates nothing when review is not required' do
    expect { call_with(skip_decision) }.not_to change(ActionReviewRequest, :count)
    result = call_with(skip_decision)
    expect(result.requires_review?).to be false
    expect(result.request).to be_nil
    expect(result.created).to be false
  end

  it 'creates one pending snapshot when review is required' do
    result = nil
    expect { result = call_with(review_decision) }.to change(ActionReviewRequest, :count).by(1)

    request = result.request
    expect(result.requires_review?).to be true
    expect(result.created).to be true
    expect(request.pending_state?).to be true
    expect(request.operation_type).to eq 'invite_creation'
    expect(request.trigger).to eq review_decision.trigger
    expect(request.signal_level).to eq review_decision.signal_level
    expect(request.policy_mode).to eq review_decision.policy_mode
    expect(request.policy_version).to eq review_decision.policy_version
    expect(request.reason_codes).to eq review_decision.reason_codes
    expect(request.evaluator_version).to eq 'eval-v1'
    expect(request.evidence).to eq('note' => 'factual')
    expect(request.actor_account).to eq actor
    expect(request.resource).to eq resource
  end

  it 'returns the existing pending request instead of duplicating on retry' do
    first = call_with(review_decision)
    second = nil
    expect { second = call_with(review_decision, evidence: { 'note' => 'retry' }) }
      .not_to change(ActionReviewRequest, :count)

    expect(second.request.id).to eq first.request.id
    expect(second.created).to be false
    expect(second.request.evidence).to eq('note' => 'factual')
  end

  it 'resolves the existing pending row when insert hits the unique index' do
    first = call_with(review_decision)
    instance = described_class.new
    allow(instance).to receive(:existing_pending).and_return(nil)
    allow(ActionReviewRequest).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, 'pending resource')

    second = instance.call(
      operation_type: 'invite_creation',
      actor_account: actor,
      resource: resource,
      decision: review_decision,
      evaluator_version: 'eval-v1',
      evidence: { 'note' => 'race' }
    )

    expect(second.request.id).to eq first.request.id
    expect(second.created).to be false
  end

  it 'does not mutate the underlying resource or create moderation side effects' do
    resource.update!(display_name: 'before')
    updated_at = resource.reload.updated_at
    allow(UserMailer).to receive(:new)

    expect { call_with(review_decision) }.not_to change(ModerationAction, :count)

    expect(resource.reload.display_name).to eq 'before'
    expect(resource.updated_at).to eq updated_at
    expect(UserMailer).not_to have_received(:new)
  end
end
