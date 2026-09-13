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
