# frozen_string_literal: true

require 'rails_helper'

# PR G shadow adaptive pacing. Test-only numbers are fixtures, not
# production defaults. Actual claimed targets must stay identical
# whether the adaptive sidecar is on or off.
RSpec.describe FollowImport::DispatchScheduler, 'adaptive remote shadow' do # rubocop:disable Metrics/BlockLength
  subject(:scheduler) { described_class.new }

  def create_import(account)
    Import.create!(
      account: account,
      type: 'following',
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
    )
  end

  def create_batch(account, owner: :scheduler, import: nil)
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

  def fixed_profile(**caps)
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: caps.fetch(:destination, 4) },
        origin: { per_tick_cap: caps.fetch(:origin, 3) },
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

  def adaptive_profile(dest_initial: 2, dest_min: 1, origin_initial: 2, origin_min: 1)
    FollowImport::AdaptiveRemoteProfile.parse(
      {
        version: 1,
        destination: {
          initial_cap: dest_initial,
          min_cap: dest_min,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        origin: {
          initial_cap: origin_initial,
          min_cap: origin_min,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        runtime: { stale_after_seconds: 60, state_ttl_seconds: 120 },
      }
    )
  end

  def enable_remote_admission(profile = fixed_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(true)
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(profile)
  end

  def enable_adaptive_shadow(profile = adaptive_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_adaptive_shadow_enabled?).and_return(true)
    allow(FollowImport::AdaptiveRemoteProfile).to receive(:from_env).and_return(profile)
  end

  def disable_adaptive_shadow
    allow(FollowImport::ExecutionPolicy).to receive(:remote_adaptive_shadow_enabled?).and_return(false)
  end

  def disable_remote_admission(profile = fixed_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(false)
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(profile)
  end

  def seed_runtime_mapping(profile, destination_domain, inbox_url)
    FollowImport::RemoteRuntimeState.new(profile: profile, now: Time.now.utc).observe(
      destination_domain: destination_domain,
      inbox_url: inbox_url,
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )
  end

  def run_pr_f_off_world(adaptive:, local:, profile: nil, adaptive_prof: nil)
    profile ||= fixed_profile(destination: 1, origin: 1)
    adaptive_prof ||= adaptive_profile(dest_initial: 1, dest_min: 1, origin_initial: 1, origin_min: 1)
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(20)
    disable_remote_admission(profile)
    adaptive ? enable_adaptive_shadow(adaptive_prof) : disable_adaptive_shadow
    RedisConfiguration.with { |redis| redis.del(FollowImport::FairnessCursor::KEY) }
    seed_runtime_mapping(profile, 'remote-a.example', 'https://shared.example/inbox')
    seed_runtime_mapping(profile, 'remote-b.example', 'https://shared.example/inbox')
    FollowImport::RemoteRuntimeState.new(profile: profile, now: Time.now.utc).observe(
      destination_domain: 'remote-a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 60,
      request_reached: true
    )
    UnavailableDomain.create!(domain: 'remote-a.example') unless UnavailableDomain.exists?(domain: 'remote-a.example')
    if adaptive
      seed_adaptive_cap(:destination, 'remote-a.example', 2, adaptive: adaptive_prof, fixed: profile)
      seed_adaptive_cap(:destination, 'remote-b.example', 2, adaptive: adaptive_prof, fixed: profile)
      seed_adaptive_cap(:origin, 'https://shared.example', 1, adaptive: adaptive_prof, fixed: profile)
    end
    account = Fabricate(:account)
    batch = create_batch(account)
    add_target(batch, 0, destination_domain: local)
    add_target(batch, 1, destination_domain: 'remote-a.example')
    add_target(batch, 2, destination_domain: 'remote-b.example')
    add_target(batch, 3, destination_domain: 'remote-a.example')
    add_target(batch, 4, destination_domain: 'remote-b.example')
    scheduler.call
    [batch, FollowImportDispatchTickObservation.last, world_snapshot(batch)]
  end

  def seed_adaptive_cap(layer, key, cap, adaptive: adaptive_profile, fixed: fixed_profile)
    writer = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive, fixed_profile: fixed)
    redis_key = layer == :origin ? writer.origin_key(key) : writer.destination_key(key)
    RedisConfiguration.with do |redis|
      redis.set(
        redis_key,
        {
          schema_version: 1,
          current_cap: cap,
          success_credit: 0,
          observed_at: Time.now.utc.iso8601,
          observed_at_unix: Time.now.utc.to_i,
          adaptive_profile_digest: adaptive.digest,
          fixed_profile_digest: fixed.digest,
        }.to_json,
        ex: 120
      )
    end
  end

  def world_snapshot(batch)
    observation = FollowImportDispatchTickObservation.last
    {
      claimed_positions: batch.targets.where(state: :queued).order(:position).pluck(:position),
      claimed_count: batch.targets.where(state: :queued).count,
      states: batch.targets.order(:position).pluck(:state),
      cursor_positions: FollowImport::FairnessCursor.new.read.last_position_by_batch.values,
      planned_count: observation.planned_count,
      claimed_observation: observation.claimed_count,
    }
  end

  def run_identical_world(adaptive:)
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    enable_remote_admission(fixed_profile(destination: 4))
    adaptive ? enable_adaptive_shadow(adaptive_profile(dest_initial: 1)) : disable_adaptive_shadow
    RedisConfiguration.with { |redis| redis.del(FollowImport::FairnessCursor::KEY) }
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }
    seed_adaptive_cap(:destination, 'remote.example', 1) if adaptive
    scheduler.call
    [batch, FollowImportDispatchTickObservation.last, world_snapshot(batch)]
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*') +
             redis.keys('follow_import:remote_adaptive:v1:*')
      keys << FollowImport::FairnessCursor::KEY
      redis.del(*keys.compact) if keys.any?
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*') +
             redis.keys('follow_import:remote_adaptive:v1:*')
      keys << FollowImport::FairnessCursor::KEY
      redis.del(*keys.compact) if keys.any?
    end
  end

  before do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(true)
    allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
      'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
      'queues' => { 'push' => { 'size' => 1, 'latency' => 0.1 } }
    )
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_in)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: { 'show_reblogs' => true } }
    end
    disable_adaptive_shadow
  end

  it 'keeps actual claims identical when adaptive shadow is on with a lower cap' do
    off_enqueues = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) { off_enqueues += 1 }
    off_batch, off_obs, off = run_identical_world(adaptive: false)
    expect(off_enqueues).to eq off[:claimed_count]
    off_batch.targets.delete_all
    off_batch.destroy!

    on_enqueues = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) { on_enqueues += 1 }
    _on_batch, on_obs, on = run_identical_world(adaptive: true)

    expect(on[:claimed_positions]).to eq off[:claimed_positions]
    expect(on[:claimed_count]).to eq off[:claimed_count]
    expect(on[:states]).to eq off[:states]
    expect(on[:planned_count]).to eq off[:planned_count]
    expect(on[:claimed_observation]).to eq off[:claimed_observation]
    expect(on[:cursor_positions]).to eq off[:cursor_positions]
    expect(on_enqueues).to eq on[:claimed_count]
    expect(on_enqueues).to eq off_enqueues
    expect(off_obs.adaptive_shadow_would_block_current_claim_count).to be_nil
    expect(on_obs.adaptive_remote_shadow_enabled).to be true
    expect(on_obs.adaptive_shadow_would_block_current_claim_count).to be > 0
  end

  it 'does not change the actual fixed plan when the adaptive profile is invalid' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(6)
    enable_remote_admission(fixed_profile(destination: 4))
    enable_adaptive_shadow(FollowImport::AdaptiveRemoteProfile.parse('{nope'))
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    expect { scheduler.call }.not_to raise_error
    observation = FollowImportDispatchTickObservation.last
    expect(batch.targets.where(state: :queued).count).to eq 4
    expect(observation.adaptive_remote_shadow_enabled).to be true
    expect(observation.adaptive_remote_configured).to be false
    expect(observation.adaptive_shadow_would_block_current_claim_count).to be_nil
  end

  it 'does not change the actual fixed plan when adaptive Redis is unavailable' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(6)
    enable_remote_admission(fixed_profile(destination: 4))
    enable_adaptive_shadow
    allow_any_instance_of(FollowImport::AdaptiveRemoteState).to receive(:redis).and_raise(Redis::BaseError, 'down')
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    expect { scheduler.call }.not_to raise_error
    expect(batch.targets.where(state: :queued).count).to eq 4
    expect(FollowImportDispatchTickObservation.last.adaptive_shadow_evaluated_current_claim_count).to eq 4
  end

  it 'still blocks exactly as PR F destination cap / Retry-After / UnavailableDomain' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    profile = fixed_profile(destination: 2)
    enable_remote_admission(profile)
    enable_adaptive_shadow
    now = Time.now.utc
    FollowImport::RemoteRuntimeState.new(profile: profile, now: now).observe(
      destination_domain: 'cooled.example',
      inbox_url: 'https://cooled.example/inbox',
      http_status: 429,
      retry_after_seconds: 60,
      request_reached: true
    )
    UnavailableDomain.create!(domain: 'dead.example')
    account = Fabricate(:account)
    batch = create_batch(account)
    4.times { |position| add_target(batch, position, destination_domain: 'capped.example') }
    add_target(batch, 4, destination_domain: 'cooled.example')
    add_target(batch, 5, destination_domain: 'dead.example')
    add_target(batch, 6, destination_domain: 'healthy.example')

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued, destination_domain: 'capped.example').count).to eq 2
    expect(batch.targets.find_by(destination_domain: 'cooled.example').reload.state).to eq 'pending'
    expect(batch.targets.find_by(destination_domain: 'dead.example').reload.state).to eq 'pending'
    expect(batch.targets.find_by(destination_domain: 'healthy.example').reload.state).to eq 'queued'
    expect(observation.skipped_destination_cap_count).to be >= 1
    expect(observation.skipped_retry_after_count).to eq 1
    expect(observation.skipped_unavailable_count).to eq 1
  end

  it 'excludes local destinations from adaptive evaluation' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    enable_remote_admission(fixed_profile(destination: 1))
    enable_adaptive_shadow(adaptive_profile(dest_initial: 1, dest_min: 1, origin_initial: 1, origin_min: 1))
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    account = Fabricate(:account)
    batch = create_batch(account)
    2.times { |position| add_target(batch, position, destination_domain: local) }
    3.times { |position| add_target(batch, position + 2, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued, destination_domain: local).count).to eq 2
    expect(batch.targets.where(state: :queued, destination_domain: 'remote.example').count).to eq 1
    expect(observation.adaptive_shadow_evaluated_current_claim_count).to eq 1
  end

  it 'evaluates destination only when mapping is absent and destination plus origin when present' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    profile = fixed_profile(destination: 8, origin: 8)
    enable_remote_admission(profile)
    enable_adaptive_shadow
    now = Time.now.utc
    FollowImport::RemoteRuntimeState.new(profile: profile, now: now).observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )
    FollowImport::RemoteRuntimeState.new(profile: profile, now: now).observe(
      destination_domain: 'b.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )
    seed_adaptive_cap(:origin, 'https://shared.example', 1, fixed: profile)
    account = Fabricate(:account)
    batch = create_batch(account)
    3.times { |position| add_target(batch, position, destination_domain: 'a.example') }
    3.times { |position| add_target(batch, position + 3, destination_domain: 'b.example') }
    3.times { |position| add_target(batch, position + 6, destination_domain: 'unmapped.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 9
    expect(observation.adaptive_shadow_origin_would_block_count).to be >= 1
    expect(observation.adaptive_shadow_would_block_current_claim_count).to be > 0
  end

  it 'increases would-block telemetry for learned-low state without changing the actual plan' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(6)
    enable_remote_admission(fixed_profile(destination: 4))
    enable_adaptive_shadow
    seed_adaptive_cap(:destination, 'remote.example', 1)
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 4
    expect(observation.adaptive_shadow_would_block_current_claim_count).to eq 3
  end

  it 'never lets a learned-high adaptive cap exceed the PR F fixed ceiling' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(6)
    fixed = fixed_profile(destination: 3)
    enable_remote_admission(fixed)
    enable_adaptive_shadow
    seed_adaptive_cap(:destination, 'remote.example', 99, fixed: fixed)
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 3
    expect(observation.adaptive_destination_cap_max).to eq 3
    expect(observation.adaptive_shadow_would_block_current_claim_count).to eq 0
  end

  it 'does not instantiate adaptive state on a GLOBAL zero-budget tick' do
    allow(FollowImport::LocalLoadEnforcement).to receive(:evaluate).and_return(
      FollowImport::LocalLoadEnforcement::Result.new(
        enabled: true,
        configured: true,
        decision: FollowImport::LocalLoadDecision.new(
          {
            state: 'overloaded',
            budget_percent: 0,
            recommended_budget: 0,
            would_skip: true,
            measurement_complete: true,
            profile_version: 2,
            profile_source: 'injected',
            profile_digest: 'd',
            reasons: [],
          }
        ),
        base_budget: 10,
        effective_budget: 0,
        fallback_used: false
      )
    )
    enable_remote_admission
    enable_adaptive_shadow
    allow(FollowImport::AdaptiveRemoteState).to receive(:new)
    allow(FollowImport::AdaptiveRemoteAdvisor).to receive(:new)
    account = Fabricate(:account)
    batch = create_batch(account)
    add_target(batch, 0, destination_domain: 'remote.example')

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(FollowImport::AdaptiveRemoteState).not_to have_received(:new)
    expect(FollowImport::AdaptiveRemoteAdvisor).not_to have_received(:new)
    expect(batch.targets.first.reload.state).to eq 'pending'
    expect(observation.adaptive_remote_shadow_enabled).to be true
    expect(observation.adaptive_shadow_evaluated_current_claim_count).to be_nil
  end

  it 'evaluates adaptive shadow from candidate destinations when PR F enforcement is off' do
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    viewed = []
    allow_any_instance_of(FollowImport::AdaptiveRemoteState::Snapshot).to receive(:view_for_destination).and_wrap_original do |orig, domain|
      viewed << domain
      orig.call(domain)
    end
    allow(FollowImport::RemoteAdmission).to receive(:new).and_call_original
    allow(FollowImport::RemoteAdmission).to receive(:unavailable_hosts).and_call_original

    off_enqueues = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) { off_enqueues += 1 }
    off_batch, off_obs, off = run_pr_f_off_world(adaptive: false, local: local)
    expect(off_enqueues).to eq off[:claimed_count]
    off_ids = off_batch.targets.where(state: :queued).order(:id).pluck(:id)
    off_batch.targets.delete_all
    off_batch.destroy!

    on_enqueues = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) { on_enqueues += 1 }
    on_batch, on_obs, on = run_pr_f_off_world(adaptive: true, local: local)

    expect(FollowImport::RemoteAdmission).not_to have_received(:new)
    expect(FollowImport::RemoteAdmission).not_to have_received(:unavailable_hosts)
    expect(on[:claimed_positions]).to eq off[:claimed_positions]
    expect(on[:claimed_count]).to eq off[:claimed_count]
    expect(on[:claimed_count]).to eq 5
    expect(on[:states]).to eq off[:states]
    expect(on[:planned_count]).to eq off[:planned_count]
    expect(on[:claimed_observation]).to eq off[:claimed_observation]
    expect(on_enqueues).to eq off_enqueues
    expect(on_batch.targets.where(state: :queued).order(:id).pluck(:destination_domain)).to contain_exactly(
      local, 'remote-a.example', 'remote-b.example', 'remote-a.example', 'remote-b.example'
    )
    expect(on_batch.targets.where(state: :queued).order(:id).pluck(:id).size).to eq off_ids.size
    expect(off_obs.adaptive_shadow_would_block_current_claim_count).to be_nil
    expect(on_obs.skipped_destination_cap_count).to be_nil.or eq(0)
    expect(on_obs.skipped_origin_cap_count).to be_nil.or eq(0)
    expect(on_obs.skipped_unavailable_count).to be_nil.or eq(0)
    expect(on_obs.skipped_retry_after_count).to be_nil.or eq(0)
    expect(on_obs.adaptive_remote_shadow_enabled).to be true
    expect(on_obs.adaptive_shadow_evaluated_current_claim_count).to eq 4
    expect(on_obs.adaptive_shadow_origin_would_block_count).to be > 0
    expect(on_obs.adaptive_shadow_would_block_current_claim_count).to be > 0
    expect(viewed).to include('remote-a.example', 'remote-b.example')
    expect(viewed).not_to include(FollowImport::RemoteAdmission::UNKNOWN_DESTINATION)
    expect(viewed).not_to include(local)
  ensure
    UnavailableDomain.find_by(domain: 'remote-a.example')&.destroy
  end

  it 'reuses one RemoteRuntimeState snapshot for fixed admission and adaptive mapping' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(4)
    profile = fixed_profile(destination: 4, origin: 4)
    enable_remote_admission(profile)
    enable_adaptive_shadow
    snapshots = []
    allow(FollowImport::RemoteRuntimeState).to receive(:new).and_wrap_original do |orig, **kwargs|
      state = orig.call(**kwargs)
      allow(state).to receive(:snapshot).and_wrap_original do |inner|
        snap = inner.call
        snapshots << snap
        snap
      end
      state
    end
    account = Fabricate(:account)
    batch = create_batch(account)
    add_target(batch, 0, destination_domain: 'remote.example')

    scheduler.call

    expect(snapshots.size).to eq 1
    expect(batch.targets.first.reload.state).to eq 'queued'
  end

  it 'does not claim adaptive evaluation in shadow scheduler mode' do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(false)
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
    enable_remote_admission
    enable_adaptive_shadow
    account = Fabricate(:account)
    batch = create_batch(account, owner: :legacy)
    4.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(observation.scheduler_mode).to eq 'shadow'
    expect(observation.adaptive_remote_shadow_enabled).to be_nil
    expect(observation.adaptive_shadow_would_block_current_claim_count).to be_nil
    expect(batch.targets.where(state: :pending).count).to eq 4
  end
end
