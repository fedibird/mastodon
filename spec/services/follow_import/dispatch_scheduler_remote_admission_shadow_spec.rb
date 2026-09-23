# frozen_string_literal: true

require 'rails_helper'

# Hypothetical fixed RemoteAdmission on the shadow planner. Test numbers
# are fixtures, not production defaults. Shadow must not claim.
RSpec.describe FollowImport::DispatchScheduler, 'remote admission shadow' do # rubocop:disable Metrics/BlockLength
  subject(:scheduler) { described_class.new }

  def create_import(account)
    Import.create!(
      account: account,
      type: 'following',
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
    )
  end

  def create_batch(account, owner: :legacy, import: nil)
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: (import || create_import(account)).id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: owner,
      dispatch_cohort: :operational,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  def add_target(batch, position, **attrs)
    batch.targets.create!({ target_key_hash: "key-#{batch.id}-#{position}", position: position }.merge(attrs))
  end

  def test_profile(**caps)
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: caps.fetch(:destination, 3) },
        origin: { per_tick_cap: caps.fetch(:origin, 2) },
        runtime: {
          mapping_ttl_seconds: caps.fetch(:mapping_ttl, 3600),
          max_retry_after_seconds: caps.fetch(:max_retry, 120),
          recent_429_cooldown_seconds: caps.fetch(:cooldown, 30),
        },
        scan: {
          max_targets_per_batch: caps.fetch(:max_targets, 50),
          max_windows_per_batch: caps.fetch(:max_windows, 8),
        },
      }
    )
  end

  def adaptive_profile(dest_initial: 1)
    FollowImport::AdaptiveRemoteProfile.parse(
      {
        version: 1,
        destination: {
          initial_cap: dest_initial,
          min_cap: 1,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        origin: {
          initial_cap: 2,
          min_cap: 1,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        runtime: { stale_after_seconds: 60, state_ttl_seconds: 120 },
      }
    )
  end

  def shadow_mode
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(false)
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
  end

  def enable_remote_shadow(profile = test_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_shadow_enabled?).and_return(true)
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(profile)
  end

  def planned_domains(result)
    result.plan.entries.map(&:destination_domain)
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
      redis.del(FollowImport::FairnessCursor::KEY)
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
      redis.del(FollowImport::FairnessCursor::KEY)
    end
    Rails.cache.delete('unavailable_domains')
  end

  before do
    allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(6)
    allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
      'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
      'queues' => { 'push' => { 'size' => 1, 'latency' => 0.1 } }
    )
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_in)
  end

  it 'is a scheduler no-op when dispatch shadow and global are both off' do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(false)
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(false)
    enable_remote_shadow
    allow(FollowImport::RemoteAdmission).to receive(:new).and_call_original
    account = Fabricate(:account)
    batch = create_batch(account)
    import_id = batch.import_id
    4.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    expect { scheduler.call }.not_to change(FollowImportDispatchTickObservation, :count)

    expect(scheduler.call.outcome).to eq 'shadow_disabled'
    expect(FollowImport::RemoteAdmission).not_to have_received(:new)
    expect(batch.targets.pluck(:state, :queued_at).uniq).to eq [['pending', nil]]
    expect(batch.reload.dispatch_owner).to eq 'legacy'
    expect(Import.exists?(import_id)).to be true
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
  end

  it 'keeps ordinary shadow planning when the remote shadow flag is off' do
    shadow_mode
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_shadow_enabled?).and_return(false)
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(test_profile(destination: 1))
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.plan.planned_count).to eq 5
    expect(observation.claimed_count).to eq 0
    expect(observation.remote_admission_enabled).to be_nil
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(observation.execution_config['remote_admission_shadow_enabled']).to be false
    expect(observation.execution_config['remote_admission_mode']).to be_nil
    expect(batch.targets.where(state: :pending).count).to eq 5
  end

  it 'hypothetically applies a valid fixed profile without mutating follow-import state' do
    shadow_mode
    enable_remote_shadow(test_profile(destination: 2))
    account = Fabricate(:account)
    batch = create_batch(account)
    import_id = batch.import_id
    5.times { |position| add_target(batch, position, destination_domain: 'a.example') }
    5.times { |position| add_target(batch, position + 5, destination_domain: 'b.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result).count { |domain| domain == 'a.example' }).to eq 2
    expect(planned_domains(result).count { |domain| domain == 'b.example' }).to eq 2
    expect(observation.planned_count).to eq 4
    expect(observation.claimed_count).to eq 0
    expect(observation.unique_destination_count).to eq 2
    expect(observation.skipped_destination_cap_count).to be > 0
    expect(observation.remote_admission_enabled).to be false
    expect(observation.remote_admission_configured).to be true
    expect(observation.remote_profile_version).to eq 1
    expect(observation.scanned_target_count).to be > 0
    expect(observation.execution_config['remote_admission_mode']).to eq 'shadow'
    expect(observation.execution_config['remote_admission_shadow_enabled']).to be true
    expect(observation.execution_config['destination_per_tick_cap']).to eq 2
    expect(batch.targets.pluck(:state).uniq).to eq ['pending']
    expect(batch.targets.pluck(:queued_at).uniq).to eq [nil]
    expect(batch.reload.dispatch_owner).to eq 'legacy'
    expect(Import.exists?(import_id)).to be true
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
  end

  it 'falls back to an ordinary shadow plan when the profile is unconfigured' do
    shadow_mode
    enable_remote_shadow(FollowImport::RemoteAdmissionProfile.unconfigured)
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.plan.planned_count).to eq 5
    expect(observation.remote_admission_configured).to be false
    expect(observation.execution_config['remote_admission_mode']).to eq 'shadow'
    expect(observation.execution_config['remote_admission_profile_source']).to eq 'unconfigured'
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(batch.targets.where(state: :pending).count).to eq 5
  end

  it 'falls back to an ordinary shadow plan when the profile is invalid' do
    shadow_mode
    enable_remote_shadow(FollowImport::RemoteAdmissionProfile.invalid('bad profile'))
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.plan.planned_count).to eq 5
    expect(observation.remote_admission_configured).to be false
    expect(observation.execution_config['remote_admission_profile_source']).to eq 'invalid'
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(batch.targets.where(state: :pending).count).to eq 5
  end

  it 'skips a Retry-After origin and still plans a healthy destination' do
    shadow_mode
    profile = test_profile(destination: 5)
    enable_remote_shadow(profile)
    FollowImport::RemoteRuntimeState.new(profile: profile, now: Time.now.utc).observe(
      destination_domain: 'blocked.example',
      inbox_url: 'https://blocked.example/inbox',
      http_status: 429,
      retry_after_seconds: 60,
      request_reached: true
    )
    account = Fabricate(:account)
    batch = create_batch(account)
    3.times { |position| add_target(batch, position, destination_domain: 'blocked.example') }
    2.times { |position| add_target(batch, position + 3, destination_domain: 'healthy.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result)).to all(eq('healthy.example'))
    expect(observation.skipped_retry_after_count).to be > 0
    expect(observation.planned_count).to eq 2
    expect(batch.targets.where(state: :pending).count).to eq 5
  end

  it 'skips a recent-429 origin and still plans a healthy destination' do
    shadow_mode
    profile = test_profile(destination: 5)
    enable_remote_shadow(profile)
    FollowImport::RemoteRuntimeState.new(profile: profile, now: Time.now.utc).observe(
      destination_domain: 'blocked.example',
      inbox_url: 'https://blocked.example/inbox',
      http_status: 429,
      retry_after_seconds: nil,
      request_reached: true
    )
    account = Fabricate(:account)
    batch = create_batch(account)
    3.times { |position| add_target(batch, position, destination_domain: 'blocked.example') }
    2.times { |position| add_target(batch, position + 3, destination_domain: 'healthy.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result)).to all(eq('healthy.example'))
    expect(observation.skipped_recent_429_count).to be > 0
    expect(batch.targets.where(state: :pending).count).to eq 5
  end

  it 'skips an UnavailableDomain destination and plans the healthy row behind it' do
    shadow_mode
    enable_remote_shadow(test_profile(destination: 5))
    UnavailableDomain.create!(domain: 'dead.example')
    Rails.cache.delete('unavailable_domains')
    account = Fabricate(:account)
    batch = create_batch(account)
    add_target(batch, 0, destination_domain: 'dead.example')
    add_target(batch, 1, destination_domain: 'healthy.example')

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result)).to eq ['healthy.example']
    expect(observation.skipped_unavailable_count).to eq 1
    expect(batch.targets.pluck(:state).uniq).to eq ['pending']
  end

  it 'still applies the destination cap when no endpoint origin has been learned' do
    shadow_mode
    enable_remote_shadow(test_profile(destination: 2))
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'unknown.example') }
    2.times { |position| add_target(batch, position + 6, destination_domain: 'other.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result).count { |domain| domain == 'unknown.example' }).to eq 2
    expect(planned_domains(result)).to include('other.example')
    expect(observation.skipped_destination_cap_count).to be > 0
    expect(observation.mapped_origin_candidate_count).to eq 0
    expect(batch.targets.where(state: :pending).count).to eq 8
  end

  it 'records scan-budget exhaustion and does not plan past the configured window' do
    shadow_mode
    allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(2)
    enable_remote_shadow(test_profile(destination: 5, max_targets: 4, max_windows: 2))
    UnavailableDomain.create!(domain: 'blocked.example')
    Rails.cache.delete('unavailable_domains')
    account = Fabricate(:account)
    batch = create_batch(account)
    10.times { |position| add_target(batch, position, destination_domain: 'blocked.example') }
    add_target(batch, 10, destination_domain: 'healthy.example')

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(planned_domains(result)).not_to include('healthy.example')
    expect(observation.scanned_target_count).to eq 4
    expect(observation.scan_budget_exhausted_count).to eq 1
    expect(observation.windows_scanned).to be <= 2
    expect(batch.targets.where(state: :pending).count).to eq 11
  end

  it 'returns unused share to another batch, another owner, and a later destination' do
    shadow_mode
    allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(4)
    enable_remote_shadow(test_profile(destination: 10, max_targets: 20, max_windows: 4))
    UnavailableDomain.create!(domain: 'blocked.example')
    Rails.cache.delete('unavailable_domains')
    first = Fabricate(:account)
    second = Fabricate(:account)
    blocked_then_later = create_batch(first)
    second_batch = create_batch(first)
    other_owner = create_batch(second)
    2.times { |position| add_target(blocked_then_later, position, destination_domain: 'blocked.example') }
    add_target(blocked_then_later, 2, destination_domain: 'later.example')
    2.times { |position| add_target(second_batch, position, destination_domain: 'same-owner.example') }
    2.times { |position| add_target(other_owner, position, destination_domain: 'other-owner.example') }

    result = scheduler.call
    domains = planned_domains(result)

    expect(domains).not_to include('blocked.example')
    expect(domains).to include('later.example')
    expect(domains).to include('same-owner.example')
    expect(domains).to include('other-owner.example')
    expect(result.plan.planned_count).to eq 4
    expect(blocked_then_later.targets.where(state: :pending).count).to eq 3
    expect(second_batch.reload.dispatch_owner).to eq 'legacy'
    expect(other_owner.reload.dispatch_owner).to eq 'legacy'
  end

  it 'does not let the shadow flag change authoritative claims when GLOBAL enforcement is off' do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(true)
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(false)
    enable_remote_shadow(test_profile(destination: 1))
    allow(FollowImport::RemoteAdmission).to receive(:new).and_call_original
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    8.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(FollowImport::RemoteAdmission).not_to have_received(:new)
    expect(batch.targets.where(state: :queued).count).to eq 5
    expect(observation.remote_admission_enabled).to be false
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(observation.execution_config['remote_admission_mode']).to eq 'disabled'
    expect(observation.scheduler_mode).to eq 'global'
  end

  it 'keeps a single authoritative RemoteAdmission when GLOBAL enforcement and the shadow flag are both on' do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(true)
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(true)
    enable_remote_shadow(test_profile(destination: 2))
    allow(FollowImport::RemoteAdmission).to receive(:new).and_call_original
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    8.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(FollowImport::RemoteAdmission).to have_received(:new).once
    expect(batch.targets.where(state: :queued).count).to eq 2
    expect(observation.claimed_count).to eq 2
    expect(observation.remote_admission_enabled).to be true
    expect(observation.execution_config['remote_admission_mode']).to eq 'enforced'
    expect(observation.skipped_destination_cap_count).to be > 0
  end

  it 'records adaptive would-block inside the fixed shadow baseline without shrinking the plan' do
    shadow_mode
    profile = test_profile(destination: 3)
    enable_remote_shadow(profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_adaptive_shadow_enabled?).and_return(true)
    allow(FollowImport::AdaptiveRemoteProfile).to receive(:from_env).and_return(adaptive_profile(dest_initial: 1))
    allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(10)
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.plan.planned_count).to eq 3
    expect(observation.adaptive_shadow_would_block_current_claim_count).to be > 0
    expect(observation.adaptive_remote_configured).to be true
    expect(observation.claimed_count).to eq 0
    expect(batch.targets.where(state: :pending).count).to eq 5
  end
end
