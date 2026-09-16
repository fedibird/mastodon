# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchScheduler, 'fixed remote admission' do
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

  def enable_remote_admission(profile = test_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(true)
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(profile)
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
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
  end

  it 'keeps PR C destination behavior when enforcement is off' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(false)
    account = Fabricate(:account)
    batch = create_batch(account)
    8.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 5
    expect(observation.remote_admission_enabled).to be false
    expect(observation.remote_admission_configured).to be_nil
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(observation.scanned_target_count).to be_nil
  end

  it 'does not silently enforce remote caps when the flag is on but the profile is missing' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    enable_remote_admission(FollowImport::RemoteAdmissionProfile.unconfigured)
    account = Fabricate(:account)
    batch = create_batch(account)
    8.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 5
    expect(observation.remote_admission_enabled).to be true
    expect(observation.remote_admission_configured).to be false
    expect(observation.skipped_destination_cap_count).to be_nil
  end

  it 'caps a single remote destination across the whole tick' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    enable_remote_admission(test_profile(destination: 3))
    account = Fabricate(:account)
    batch = create_batch(account)
    10.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 3
    expect(observation.claimed_count).to eq 3
    expect(observation.planned_count).to eq 3
    expect(observation.skipped_destination_cap_count).to be >= 1
    expect(observation.remote_admission_configured).to be true
    expect(observation.execution_config['destination_per_tick_cap']).to eq 3
  end

  it 'does not multiply the destination cap when one account splits a CSV' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(20)
    enable_remote_admission(test_profile(destination: 3))
    account = Fabricate(:account)
    10.times do
      batch = create_batch(account)
      3.times { |position| add_target(batch, position, destination_domain: 'remote.example') }
    end

    scheduler.call

    claimed = FollowImportTarget.joins(:batch).merge(FollowImportBatch.scheduler_owned)
                                .where(state: :queued, destination_domain: 'remote.example')
                                .count
    expect(claimed).to eq 3
  end

  it 'shares finite destination capacity across accounts through owner rotation' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(6)
    enable_remote_admission(test_profile(destination: 4))
    first = Fabricate(:account)
    second = Fabricate(:account)
    10.times do
      batch = create_batch(first)
      add_target(batch, 0, destination_domain: 'remote.example')
    end
    single = create_batch(second)
    6.times { |position| add_target(single, position, destination_domain: 'remote.example') }

    scheduler.call

    first_claimed = FollowImportTarget.joins(:batch).merge(FollowImportBatch.scheduler_owned)
                                      .where(state: :queued, follow_import_batches: { subject_id: ModerationSubject.for_account!(first).id })
                                      .count
    second_claimed = single.targets.where(state: :queued).count

    expect(first_claimed + second_claimed).to eq 4
    expect((first_claimed - second_claimed).abs).to be <= 1
    expect(first_claimed).to be < 10
  end

  it 'enforces a shared origin cap when a fresh mapping is known' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    profile = test_profile(destination: 5, origin: 2)
    enable_remote_admission(profile)
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
    account = Fabricate(:account)
    batch = create_batch(account)
    4.times { |position| add_target(batch, position, destination_domain: 'a.example') }
    4.times { |position| add_target(batch, position + 4, destination_domain: 'b.example') }
    3.times { |position| add_target(batch, position + 8, destination_domain: 'c.example') }

    scheduler.call

    expect(batch.targets.where(state: :queued, destination_domain: %w(a.example b.example)).count).to eq 2
    expect(batch.targets.where(state: :queued, destination_domain: 'c.example').count).to eq 3
    expect(FollowImportDispatchTickObservation.last.skipped_origin_cap_count).to be >= 1
  end

  it 'does not consume remote destination cap for local targets' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    enable_remote_admission(test_profile(destination: 1))
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    account = Fabricate(:account)
    batch = create_batch(account)
    2.times { |position| add_target(batch, position, destination_domain: local) }
    3.times { |position| add_target(batch, position + 2, destination_domain: 'remote.example') }

    scheduler.call

    expect(batch.targets.where(state: :queued, destination_domain: local).count).to eq 2
    expect(batch.targets.where(state: :queued, destination_domain: 'remote.example').count).to eq 1
  end

  it 'skips an exact UnavailableDomain destination and keeps the row pending' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(3)
    enable_remote_admission(test_profile(destination: 3))
    UnavailableDomain.create!(domain: 'dead.example')
    account = Fabricate(:account)
    batch = create_batch(account)
    blocked = add_target(batch, 0, destination_domain: 'dead.example')
    healthy = add_target(batch, 1, destination_domain: 'healthy.example')

    scheduler.call

    expect(blocked.reload.state).to eq 'pending'
    expect(healthy.reload.state).to eq 'queued'
    expect(FollowImportDispatchTickObservation.last.skipped_unavailable_count).to eq 1
  end

  it 'lets a healthy account progress when another account is only blocked' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(3)
    enable_remote_admission(test_profile(destination: 3))
    UnavailableDomain.create!(domain: 'blocked.example')
    first = Fabricate(:account)
    second = Fabricate(:account)
    blocked_batch = create_batch(first)
    healthy_batch = create_batch(second)
    4.times { |position| add_target(blocked_batch, position, destination_domain: 'blocked.example') }
    4.times { |position| add_target(healthy_batch, position, destination_domain: 'healthy.example') }

    scheduler.call

    expect(blocked_batch.targets.where(state: :queued).count).to eq 0
    expect(healthy_batch.targets.where(state: :queued).count).to eq 3
    expect(FollowImportDispatchTickObservation.last.claimed_count).to eq 3
  end

  it 'pages past a blocked prefix inside the scan budget and claims the healthy row' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(1)
    enable_remote_admission(test_profile(destination: 3, max_targets: 120, max_windows: 20))
    UnavailableDomain.create!(domain: 'blocked.example')
    account = Fabricate(:account)
    batch = create_batch(account)
    100.times { |position| add_target(batch, position, destination_domain: 'blocked.example') }
    healthy = add_target(batch, 100, destination_domain: 'healthy.example')

    scheduler.call

    expect(healthy.reload.state).to eq 'queued'
    expect(batch.targets.where(state: :pending).count).to eq 100
    expect(FollowImportDispatchTickObservation.last.scan_budget_exhausted_count).to eq 0
    expect(FollowImportDispatchTickObservation.last.scanned_target_count).to eq 101
  end

  it 'does not claim a healthy row outside the scan budget on the first tick, then reaches it later' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(1)
    enable_remote_admission(test_profile(destination: 3, max_targets: 20, max_windows: 3))
    UnavailableDomain.create!(domain: 'blocked.example')
    account = Fabricate(:account)
    batch = create_batch(account)
    100.times { |position| add_target(batch, position, destination_domain: 'blocked.example') }
    healthy = add_target(batch, 100, destination_domain: 'healthy.example')

    first = scheduler.call
    expect(healthy.reload.state).to eq 'pending'
    expect(first.plan.scan_budget_exhausted_count).to eq 1
    expect(first.plan.scanned_target_count).to eq 20

    claimed = false
    6.times do
      scheduler.call
      if healthy.reload.state == 'queued'
        claimed = true
        break
      end
    end

    expect(claimed).to be true
    expect(batch.targets.where(state: :pending, destination_domain: 'blocked.example').count).to eq 100
  end

  it 'does not scan 20_000 blocked rows when the scan budget is small' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    enable_remote_admission(test_profile(destination: 3, max_targets: 16, max_windows: 2))
    account = Fabricate(:account)
    batch = create_batch(account)
    now = Time.now.utc
    rows = 20_000.times.map do |position|
      {
        batch_id: batch.id,
        target_key_hash: "bulk-#{position}",
        position: position,
        state: 0,
        destination_domain: 'blocked.example',
        delivery_attempts: 0,
        created_at: now,
        updated_at: now,
      }
    end
    FollowImportTarget.insert_all(rows)
    UnavailableDomain.create!(domain: 'blocked.example')

    selects = []
    callback = lambda do |*_args, payload|
      sql = payload[:sql]
      next unless sql.include?('follow_import_targets')
      next unless sql.include?('SELECT')
      next if sql.include?('COUNT')
      next if sql.include?('DISTINCT')

      selects << sql
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      scheduler.call
    end

    expect(batch.targets.where(state: :queued).count).to eq 0
    expect(FollowImportDispatchTickObservation.last.scanned_target_count).to be <= 16
    expect(FollowImportDispatchTickObservation.last.windows_scanned).to be <= 2
    expect(selects.size).to be <= 4
    expect(selects.join).not_to match(/LIMIT\s+20000/i)
  end

  it 'still applies the destination cap when Redis runtime state cannot be read' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    enable_remote_admission(test_profile(destination: 2))
    allow_any_instance_of(FollowImport::RemoteRuntimeState).to receive(:redis).and_raise(Redis::BaseError, 'down')
    account = Fabricate(:account)
    batch = create_batch(account)
    6.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    expect { scheduler.call }.not_to raise_error
    expect(batch.targets.where(state: :queued).count).to eq 2
  end

  it 'does not discover work or build remote admission state on a GLOBAL zero-budget tick' do
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
    allow(FollowImport::RemoteAdmission).to receive(:new)
    allow(FollowImport::PendingBatchSource).to receive(:new)
    account = Fabricate(:account)
    batch = create_batch(account)
    add_target(batch, 0, destination_domain: 'remote.example')

    scheduler.call

    expect(FollowImport::RemoteAdmission).not_to have_received(:new)
    expect(FollowImport::PendingBatchSource).not_to have_received(:new)
    expect(batch.targets.first.reload.state).to eq 'pending'
    expect(FollowImportDispatchTickObservation.last.scanned_target_count).to be_nil
  end

  it 'restores PR C destination behavior on the next tick after the flag is turned off' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    enable_remote_admission(test_profile(destination: 1))
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    expect(batch.targets.where(state: :queued).count).to eq 1

    allow(FollowImport::ExecutionPolicy).to receive(:remote_admission_enforcement_enabled?).and_return(false)
    scheduler.call

    expect(batch.targets.where(state: :queued).count).to eq 5
  end

  it 'does not treat shadow mode as remote-admission evaluation' do
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(false)
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
    enable_remote_admission(test_profile(destination: 1))
    account = Fabricate(:account)
    batch = create_batch(account, owner: :legacy)
    4.times { |position| add_target(batch, position, destination_domain: 'remote.example') }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(observation.scheduler_mode).to eq 'shadow'
    expect(observation.claimed_count).to eq 0
    expect(observation.remote_admission_enabled).to be_nil
    expect(observation.skipped_destination_cap_count).to be_nil
    expect(batch.targets.where(state: :pending).count).to eq 4
  end

  it 'does not apply remote admission to a legacy BatchExecutionWorker pass' do
    enable_remote_admission(test_profile(destination: 1))
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(false)
    account = Fabricate(:account)
    batch = create_batch(account, owner: :legacy)
    4.times { |position| add_target(batch, position, destination_domain: 'remote.example') }
    allow(Sidekiq::Queue).to receive(:new).and_return(instance_double(Sidekiq::Queue, size: 1, latency: 0.2))
    allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 0))
    allow(Sidekiq::ProcessSet).to receive(:new).and_return([])
    allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
      .and_return({ 'proposed_friction' => 'allow' })

    FollowImport::BatchExecutionWorker.new.perform(batch.id)

    expect(batch.targets.where(state: :queued).count).to eq 4
  end

  def persist_cursor(batch, position)
    owner_key = FollowImport::OwnerKey.for_batch(batch).to_s
    FollowImport::FairnessCursor.new.write(
      FollowImport::FairnessCursor::State.new(
        last_owner_key: owner_key,
        last_batch_by_owner: { owner_key => batch.id },
        last_position_by_batch: { batch.id.to_s => position },
        source: FollowImport::FairnessCursor::SOURCE_REDIS
      ),
      active_owner_keys: [owner_key],
      active_batch_ids: [batch.id]
    )
  end

  it 'wraps and inspects the head when the cursor is at the last row and max_windows is 1' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(1)
    enable_remote_admission(test_profile(destination: 3, max_targets: 8, max_windows: 1))
    account = Fabricate(:account)
    batch = create_batch(account)
    5.times { |position| add_target(batch, position, destination_domain: 'healthy.example') }
    persist_cursor(batch, 4)

    scheduler.call

    expect(batch.targets.where(state: :queued).count).to eq 1
    expect(batch.targets.order(:position).first.reload.state).to eq 'queued'
    expect(FollowImport::FairnessCursor.new.read.last_position_by_batch[batch.id.to_s]).not_to eq 4
  end

  it 'reconsiders a previously blocked row after the cursor wraps and the block clears' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(1)
    enable_remote_admission(test_profile(destination: 3, max_targets: 8, max_windows: 1))
    blocked = UnavailableDomain.create!(domain: 'blocked.example')
    account = Fabricate(:account)
    batch = create_batch(account)
    targets = 3.times.map { |position| add_target(batch, position, destination_domain: 'blocked.example') }

    first = scheduler.call
    expect(targets.map { |target| target.reload.state }.uniq).to eq %w(pending)
    expect(first.plan.scanned_target_count).to be_positive
    cursor_after_first = FollowImport::FairnessCursor.new.read.last_position_by_batch[batch.id.to_s]
    expect(cursor_after_first).to eq 2

    second = scheduler.call
    expect(targets.map { |target| target.reload.state }.uniq).to eq %w(pending)
    expect(second.plan.scanned_target_count).to be_positive

    blocked.destroy!
    Rails.cache.delete('unavailable_domains')

    scheduler.call
    expect(targets.count { |target| target.reload.state == 'queued' }).to eq 1
    expect(targets.all? { |target| target.reload.state.in?(%w(pending queued)) }).to be true
  end
end
