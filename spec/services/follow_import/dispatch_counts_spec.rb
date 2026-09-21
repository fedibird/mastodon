# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchCounts do # rubocop:disable Metrics/BlockLength
  def create_batch(**attrs)
    FollowImportBatch.create!(
      {
        subject: Fabricate(:moderation_subject),
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0,
      }.merge(attrs)
    )
  end

  it 'counts pending targets per batch and globally without loading accounts' do
    first = create_batch
    second = create_batch
    first.targets.create!(target_key_hash: 'a', position: 0)
    first.targets.create!(target_key_hash: 'b', position: 1, state: :queued)
    second.targets.create!(target_key_hash: 'c', position: 0)

    expect(described_class.pending_for(first)).to eq 1
    expect(described_class.global_pending).to eq 2
    expect(described_class.active_batches).to eq 2
  end

  it 'returns 0 when a set is observed empty' do
    batch = create_batch
    expect(described_class.pending_for(batch)).to eq 0
  end

  it 'returns nil when a count cannot be measured' do
    batch = create_batch
    allow(batch).to receive(:targets).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(FollowImportTarget).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect(described_class.pending_for(batch)).to be_nil
    expect(described_class.global_pending).to be_nil
    expect(described_class.active_batches).to be_nil
  end

  it 'splits backlog universes by durable cohort and planning scope' do
    historical_legacy = create_batch(dispatch_owner: :legacy, dispatch_cohort: :historical)
    operational_legacy = create_batch(dispatch_owner: :legacy, dispatch_cohort: :operational)
    operational_scheduler = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational)
    historical_legacy.targets.create!(target_key_hash: 'h1', position: 0)
    historical_legacy.targets.create!(target_key_hash: 'h2', position: 1)
    operational_legacy.targets.create!(target_key_hash: 'ol', position: 0)
    operational_scheduler.targets.create!(target_key_hash: 'os', position: 0)
    operational_scheduler.targets.create!(target_key_hash: 'queued', position: 1, state: :queued)

    shadow = described_class.backlog_snapshot(planning_scope: FollowImportBatch.shadow_planning_scope)
    global = described_class.backlog_snapshot(planning_scope: FollowImportBatch.global_planning_scope)

    expect(shadow.global_pending_count).to eq 4
    expect(shadow.active_batch_count).to eq 3
    expect(shadow.historical_pending_count).to eq 2
    expect(shadow.historical_active_batch_count).to eq 1
    expect(shadow.operational_pending_count).to eq 2
    expect(shadow.operational_active_batch_count).to eq 2
    expect(shadow.planning_pending_count).to eq 2
    expect(shadow.planning_active_batch_count).to eq 2

    expect(global.global_pending_count).to eq 4
    expect(global.historical_pending_count).to eq 2
    expect(global.operational_pending_count).to eq 2
    expect(global.planning_pending_count).to eq 1
    expect(global.planning_active_batch_count).to eq 1
  end

  it 'returns 0 for an observed-empty cohort rather than NULL' do
    historical = create_batch(dispatch_cohort: :historical)
    historical.targets.create!(target_key_hash: 'only-historical', position: 0)

    snapshot = described_class.backlog_snapshot(planning_scope: FollowImportBatch.shadow_planning_scope)

    expect(snapshot.global_pending_count).to eq 1
    expect(snapshot.historical_pending_count).to eq 1
    expect(snapshot.operational_pending_count).to eq 0
    expect(snapshot.planning_pending_count).to eq 0
    expect(snapshot.operational_active_batch_count).to eq 0
    expect(snapshot.planning_active_batch_count).to eq 0
  end

  it 'returns NULL scoped counts when pending measurement cannot run' do
    allow(FollowImportTarget).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'boom')

    snapshot = described_class.backlog_snapshot(planning_scope: FollowImportBatch.shadow_planning_scope)

    expect(snapshot.global_pending_count).to be_nil
    expect(snapshot.active_batch_count).to be_nil
    expect(snapshot.historical_pending_count).to be_nil
    expect(snapshot.operational_pending_count).to be_nil
    expect(snapshot.planning_pending_count).to be_nil
    expect(snapshot.historical_active_batch_count).to be_nil
    expect(snapshot.operational_active_batch_count).to be_nil
    expect(snapshot.planning_active_batch_count).to be_nil
  end

  it 'does not load pending target rows to classify the backlog' do
    historical = create_batch(dispatch_cohort: :historical)
    operational = create_batch(dispatch_cohort: :operational, dispatch_owner: :legacy)
    8.times { |position| historical.targets.create!(target_key_hash: "h-#{position}", position: position) }
    operational.targets.create!(target_key_hash: 'live', position: 0)

    target_row_selects = []
    callback = lambda do |*_args, payload|
      query = payload[:sql]
      next unless query.include?('follow_import_targets')
      next unless query.include?('SELECT')
      next if query.match?(/COUNT/i) || query.include?('DISTINCT')

      target_row_selects << query
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.backlog_snapshot(planning_scope: FollowImportBatch.shadow_planning_scope)
    end

    expect(target_row_selects).to be_empty
  end
end
