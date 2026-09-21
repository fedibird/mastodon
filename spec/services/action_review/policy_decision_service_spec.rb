# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::PolicyDecisionService do # rubocop:disable Metrics/BlockLength
  subject(:service) { described_class.new }

  def decide(operation_type: 'follow_import', signal_level: 'none', evaluation_status: 'ok', policy_mode: 'off')
    service.call(
      operation_type: operation_type,
      signal_level: signal_level,
      evaluation_status: evaluation_status,
      policy_mode: policy_mode
    )
  end

  it 'never reviews under off for none/low/medium/high' do
    %w(none low medium high).each do |signal|
      result = decide(signal_level: signal, policy_mode: 'off')
      expect(result.requires_review?).to be false
      expect(result.trigger).to eq 'none'
      expect(result.reason_codes).to eq []
    end
  end

  it 'reviews only high under the high threshold' do
    expect(decide(signal_level: 'none', policy_mode: 'high').requires_review?).to be false
    expect(decide(signal_level: 'low', policy_mode: 'high').requires_review?).to be false
    expect(decide(signal_level: 'medium', policy_mode: 'high').requires_review?).to be false
    high = decide(signal_level: 'high', policy_mode: 'high')
    expect(high.requires_review?).to be true
    expect(high.trigger).to eq 'policy'
    expect(high.reason_codes).to include('policy_high', 'signal_high')
  end

  it 'reviews medium and high under the medium threshold' do
    expect(decide(signal_level: 'none', policy_mode: 'medium').requires_review?).to be false
    expect(decide(signal_level: 'low', policy_mode: 'medium').requires_review?).to be false
    expect(decide(signal_level: 'medium', policy_mode: 'medium').requires_review?).to be true
    expect(decide(signal_level: 'high', policy_mode: 'medium').requires_review?).to be true
  end

  it 'reviews low, medium, and high under the low threshold' do
    expect(decide(signal_level: 'none', policy_mode: 'low').requires_review?).to be false
    expect(decide(signal_level: 'low', policy_mode: 'low').requires_review?).to be true
    expect(decide(signal_level: 'medium', policy_mode: 'low').requires_review?).to be true
    expect(decide(signal_level: 'high', policy_mode: 'low').requires_review?).to be true
  end

  it 'reviews every signal level under always' do
    %w(none low medium high).each do |signal|
      result = decide(signal_level: signal, policy_mode: 'always')
      expect(result.requires_review?).to be true
      expect(result.trigger).to eq 'policy'
      expect(result.reason_codes).to include('policy_always')
    end
  end

  it 'requires review when a threshold policy cannot evaluate' do
    result = decide(signal_level: 'none', policy_mode: 'medium', evaluation_status: 'error')
    expect(result.requires_review?).to be true
    expect(result.trigger).to eq 'evaluator_unavailable'
    expect(result.reason_codes).to eq %w(evaluator_unavailable)
  end

  it 'does not require review when policy is off and evaluation fails' do
    result = decide(signal_level: 'high', policy_mode: 'off', evaluation_status: 'error')
    expect(result.requires_review?).to be false
    expect(result.trigger).to eq 'none'
  end

  it 'still requires review when policy is always and evaluation fails' do
    result = decide(signal_level: 'none', policy_mode: 'always', evaluation_status: 'error')
    expect(result.requires_review?).to be true
    expect(result.trigger).to eq 'policy'
    expect(result.reason_codes).to include('policy_always', 'evaluator_unavailable')
  end

  it 'does not invent a signal for a detectorless operation' do
    off = decide(operation_type: 'invite_creation', signal_level: 'none', policy_mode: 'off')
    always = decide(operation_type: 'account_migration', signal_level: 'none', policy_mode: 'always')

    expect(off.requires_review?).to be false
    expect(off.signal_level).to eq 'none'
    expect(always.requires_review?).to be true
    expect(always.signal_level).to eq 'none'
  end

  it 'returns a factual snapshot with the policy version and no score' do
    result = decide(signal_level: 'high', policy_mode: 'high')

    expect(result.operation_type).to eq 'follow_import'
    expect(result.policy_mode).to eq 'high'
    expect(result.policy_version).to eq 'action-review-policy-v1'
    expect(result.trigger).to eq 'policy'
    expect(result.reason_codes).to be_an(Array)
    expect(result).not_to respond_to(:score)
    expect(result).not_to respond_to(:guilt)
    expect(result).not_to respond_to(:identity)
  end

  it 'reads site policy by default' do
    allow(ActionReview::PolicySettings).to receive(:mode_for).with('follow_import').and_return('always')

    result = service.call(operation_type: 'follow_import', signal_level: 'none')

    expect(result.policy_mode).to eq 'always'
    expect(result.requires_review?).to be true
  end

  it 'rejects an unknown operation rather than treating it as off' do
    expect { decide(operation_type: 'not_registered') }
      .to raise_error(ActionReview::OperationRegistry::UnknownOperation)
  end
end
