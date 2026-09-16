# frozen_string_literal: true

require 'rails_helper'
require 'erb'
require 'yaml'

RSpec.describe FollowImport::ExecutionPolicy do
  it 'exposes a single response_wait duration' do
    expect(described_class.response_wait).to be_a(ActiveSupport::Duration)
    expect(described_class.response_wait).to be > 0
  end

  it 'derives the response deadline from a given start time' do
    from = Time.utc(2026, 1, 1, 0, 0, 0)
    expect(described_class.response_deadline_at(from)).to eq(from + described_class.response_wait)
  end

  describe 'execution pacing knobs' do
    it 'defaults the batch size and reschedule interval to positive values' do
      expect(described_class.execution_batch_size).to be > 0
      expect(described_class.execution_reschedule_in).to be_a(ActiveSupport::Duration)
      expect(described_class.execution_reschedule_in).to be > 0
    end

    it 'reads a positive batch size override from the environment' do
      ClimateControl.modify FOLLOW_IMPORT_EXECUTION_BATCH_SIZE: '7' do
        expect(described_class.execution_batch_size).to eq 7
      end
    end

    it 'ignores a non-positive batch size override' do
      ClimateControl.modify FOLLOW_IMPORT_EXECUTION_BATCH_SIZE: '0' do
        expect(described_class.execution_batch_size).to eq described_class::DEFAULT_BATCH_SIZE
      end
    end

    it 'reads a positive reschedule interval override from the environment' do
      ClimateControl.modify FOLLOW_IMPORT_EXECUTION_INTERVAL: '120' do
        expect(described_class.execution_reschedule_in).to eq 120.seconds
      end
    end
  end

  describe '.gate_enforcement_enabled?' do
    it 'is disabled by default' do
      expect(described_class.gate_enforcement_enabled?).to be false
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_GATE_ENFORCEMENT: 'true' do
        expect(described_class.gate_enforcement_enabled?).to be true
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_GATE_ENFORCEMENT: '1' do
        expect(described_class.gate_enforcement_enabled?).to be false
      end
    end
  end

  describe '.dispatch_shadow_enabled?' do
    it 'is disabled by default' do
      expect(described_class.dispatch_shadow_enabled?).to be false
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW: 'true' do
        expect(described_class.dispatch_shadow_enabled?).to be true
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW: '1' do
        expect(described_class.dispatch_shadow_enabled?).to be false
      end
    end
  end

  describe '.dispatch_global_enabled?' do
    it 'is disabled by default' do
      expect(described_class.dispatch_global_enabled?).to be false
      expect(described_class.intended_dispatch_owner).to eq :legacy
      expect(described_class.dispatch_scheduler_mode).to be_nil
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
        expect(described_class.dispatch_global_enabled?).to be true
        expect(described_class.intended_dispatch_owner).to eq :scheduler
        expect(described_class.dispatch_scheduler_mode).to eq :global
      end
    end

    it 'takes precedence over shadow when both flags are on' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true', FOLLOW_IMPORT_DISPATCH_SHADOW: 'true' do
        expect(described_class.dispatch_scheduler_mode).to eq :global
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: '1' do
        expect(described_class.dispatch_global_enabled?).to be false
        expect(described_class.intended_dispatch_owner).to eq :legacy
      end
    end
  end

  describe '.dispatch_interval' do
    def parsed_sidekiq_every
      path = Rails.root.join('config/sidekiq.yml')
      erb = ERB.new(File.read(path), trim_mode: '-')
      yaml = YAML.safe_load(erb.result, permitted_classes: [Symbol], aliases: true)
      yaml.fetch(:scheduler).fetch(:schedule).fetch('follow_import_dispatch_scheduler').fetch('every')
    end

    it 'exposes a provisional cadence distinct from execution pacing' do
      expect(described_class.dispatch_interval).to eq 60.seconds
      expect(described_class.dispatch_interval).not_to eq described_class.execution_reschedule_in
    end

    it 'is the single source of truth for the Sidekiq scheduler registration' do
      expect(described_class.dispatch_every).to eq '60s'
      expect(parsed_sidekiq_every).to eq described_class.dispatch_every
      expect(described_class::DEFAULT_DISPATCH_INTERVAL_SECONDS).to eq 60
    end

    it 'honors the canonical ENV override in both ExecutionPolicy and sidekiq.yml' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_INTERVAL: '90' do
        expect(described_class.dispatch_interval).to eq 90.seconds
        expect(described_class.dispatch_every).to eq '90s'
        expect(parsed_sidekiq_every).to eq '90s'
      end
    end

    it 'accepts the deprecated shadow interval alias when the canonical ENV is absent' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL: '75' do
        expect(described_class.dispatch_interval).to eq 75.seconds
        expect(described_class.dispatch_shadow_every).to eq '75s'
        expect(parsed_sidekiq_every).to eq '75s'
      end
    end

    it 'lets the canonical cadence win when both variables are set' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_INTERVAL: '45', FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL: '90' do
        expect(described_class.dispatch_interval).to eq 45.seconds
        expect(parsed_sidekiq_every).to eq '45s'
      end
    end

    it 'ignores a non-positive cadence override' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_INTERVAL: '0', FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL: '0' do
        expect(described_class.dispatch_every).to eq '60s'
        expect(parsed_sidekiq_every).to eq '60s'
      end
    end
  end

  describe '.global_dispatch_budget' do
    it 'defaults to the legacy execution batch size' do
      expect(described_class.global_dispatch_budget).to eq described_class.execution_batch_size
    end

    it 'reads a positive global per-tick ceiling' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL_BUDGET: '8' do
        expect(described_class.global_dispatch_budget).to eq 8
      end
    end

    it 'does not silently use the shadow planning budget' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL_BUDGET: '4', FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET: '99' do
        expect(described_class.global_dispatch_budget).to eq 4
        expect(described_class.shadow_plan_budget).to eq 99
      end
    end

    it 'falls back when the override is not a positive integer' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL_BUDGET: '0' do
        expect(described_class.global_dispatch_budget).to eq described_class.execution_batch_size
      end
    end
  end

  describe '.shadow_plan_budget' do
    it 'defaults to the legacy execution batch size' do
      expect(described_class.shadow_plan_budget).to eq described_class.execution_batch_size
    end

    it 'reads a positive diagnostic override' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET: '12' do
        expect(described_class.shadow_plan_budget).to eq 12
      end
    end

    it 'falls back when the override is not a positive integer' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET: '0' do
        expect(described_class.shadow_plan_budget).to eq described_class.execution_batch_size
      end
    end
  end

  describe '.local_load_shadow_enabled?' do
    it 'is disabled by default' do
      expect(described_class.local_load_shadow_enabled?).to be false
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_SHADOW: 'true' do
        expect(described_class.local_load_shadow_enabled?).to be true
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_SHADOW: '1' do
        expect(described_class.local_load_shadow_enabled?).to be false
      end
    end
  end

  describe '.local_load_enforcement_enabled?' do
    it 'is disabled by default' do
      expect(described_class.local_load_enforcement_enabled?).to be false
    end

    it 'is independent of the dispatch-shadow flag' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW: 'true', FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT: 'true' do
        expect(described_class.dispatch_shadow_enabled?).to be true
        expect(described_class.local_load_enforcement_enabled?).to be true
      end
    end

    it 'can be enabled while the global shadow scheduler stays off' do
      ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT: 'true' do
        expect(described_class.local_load_enforcement_enabled?).to be true
        expect(described_class.dispatch_shadow_enabled?).to be false
        expect(described_class.local_load_shadow_enabled?).to be false
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT: '1' do
        expect(described_class.local_load_enforcement_enabled?).to be false
      end
    end
  end

  describe '.remote_admission_enforcement_enabled?' do
    it 'is disabled by default' do
      expect(described_class.remote_admission_enforcement_enabled?).to be false
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADMISSION_ENFORCEMENT: 'true' do
        expect(described_class.remote_admission_enforcement_enabled?).to be true
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADMISSION_ENFORCEMENT: '1' do
        expect(described_class.remote_admission_enforcement_enabled?).to be false
      end
    end

    it 'does not depend on DISPATCH_SHADOW' do
      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_SHADOW: 'true' do
        expect(described_class.remote_admission_enforcement_enabled?).to be false
      end
    end
  end

  describe '.remote_adaptive_shadow_enabled?' do
    it 'is disabled by default' do
      expect(described_class.remote_adaptive_shadow_enabled?).to be false
    end

    it 'is enabled only when the explicit flag is set to true' do
      ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADAPTIVE_SHADOW: 'true' do
        expect(described_class.remote_adaptive_shadow_enabled?).to be true
      end
    end

    it 'stays disabled for any other flag value' do
      ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADAPTIVE_SHADOW: '1' do
        expect(described_class.remote_adaptive_shadow_enabled?).to be false
      end
    end

    it 'does not enable PR H enforcement' do
      expect(described_class).not_to respond_to(:remote_adaptive_enforcement_enabled?)
    end
  end
end

