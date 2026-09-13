# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ExecutionGate do
  let(:account) { Fabricate(:account) }

  def stub_friction(value)
    allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
      .and_return({ 'proposed_friction' => value, 'policy_version' => 'v', 'params_digest' => 'd', 'subject_id' => 1 })
  end

  describe 'shadow by default (enforcement off)' do
    %w(allow rate_limit confirm_target delay moderator_review).each do |friction|
      it "executes regardless of a #{friction} proposal" do
        stub_friction(friction)
        gate = described_class.for_account(account)

        expect(gate.friction).to eq friction
        expect(gate.execute?).to be true
        expect(gate.observation['shadow']).to be true
        expect(gate.observation['enforced']).to be false
      end
    end
  end

  describe 'when enforcement is explicitly enabled' do
    before { allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true) }

    {
      'allow'            => true,
      'rate_limit'       => true,
      'confirm_target'   => true,
      'delay'            => false,
      'moderator_review' => false,
    }.each do |friction, executes|
      it "maps #{friction} to execute?=#{executes}" do
        stub_friction(friction)
        gate = described_class.for_account(account)

        expect(gate.execute?).to be executes
        expect(gate.observation['shadow']).to be false
        expect(gate.observation['enforced']).to be true
      end
    end
  end

  # Real AdaptiveFollowGateDecisionService (not a stubbed friction): v1
  # calibration must keep the execution mapping unchanged.
  describe 'v1 calibration through the real decision service' do
    def stub_scores(**scores)
      dims = %w(contact_volume velocity rejection report follow_import repeat_behavior)
      subscores = dims.index_with { |d| { 'score' => scores.fetch(d.to_sym, 0.0), 'reason_codes' => [] } }
      allow_any_instance_of(Moderation::RiskEvaluationService).to receive(:call)
        .and_return('subject_id' => 1, 'subscores' => subscores, 'policy_version' => 'risk-test', 'params_digest' => 'sha256:t')
    end

    it 'velocity-only is rate_limit and still executes when enforcement is on' do
      allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true)
      stub_scores(velocity: 1.0)

      gate = described_class.for_account(account)

      expect(gate.friction).to eq 'rate_limit'
      expect(gate.execute?).to be true
    end

    it 'remote rejection >= 0.5 is delay: execute? is false when enforced, true in shadow' do
      stub_scores(rejection: 0.5)

      shadow = described_class.for_account(account)
      expect(shadow.friction).to eq 'delay'
      expect(shadow.execute?).to be true

      allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true)
      enforced = described_class.for_account(account)
      expect(enforced.friction).to eq 'delay'
      expect(enforced.execute?).to be false
    end
  end

  describe 'failure tolerance' do
    it 'fails open (execute) when the evaluator raises, even under enforcement' do
      allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true)
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call).and_raise(StandardError, 'boom')

      gate = described_class.for_account(account)

      expect(gate.friction).to eq 'allow'
      expect(gate.execute?).to be true
    end
  end
end
