# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::PendingBatchSource do
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

  it 'defaults to the operational shadow planning scope' do
    historical = create_batch(dispatch_cohort: :historical, dispatch_owner: :legacy)
    operational = create_batch(dispatch_cohort: :operational, dispatch_owner: :legacy)
    historical.targets.create!(target_key_hash: 'old', position: 0)
    operational.targets.create!(target_key_hash: 'live', position: 0)

    owners, skipped = described_class.new.owner_work(cursor: FollowImport::FairnessCursor::State.empty)

    expect(skipped).to eq 0
    expect(owners.flat_map { |owner| owner[:batches].map { |batch| batch[:id] } }).to eq [operational.id]
  end

  it 'does not surface a screening operational batch as executable owner work' do
    screening = create_batch(dispatch_cohort: :operational, dispatch_owner: :legacy, preflight_state: :screening)
    ready = create_batch(dispatch_cohort: :operational, dispatch_owner: :legacy, preflight_state: :ready)
    screening.targets.create!(target_key_hash: 'held', position: 0)
    ready.targets.create!(target_key_hash: 'live', position: 0)

    owners, skipped = described_class.new.owner_work(cursor: FollowImport::FairnessCursor::State.empty)

    expect(skipped).to eq 0
    expect(owners.flat_map { |owner| owner[:batches].map { |batch| batch[:id] } }).to eq [ready.id]
  end

  it 'does not load pending target rows during batch discovery' do
    batch = create_batch(dispatch_cohort: :operational, dispatch_owner: :legacy)
    12.times { |position| batch.targets.create!(target_key_hash: "t-#{position}", position: position) }

    target_row_selects = []
    callback = lambda do |*_args, payload|
      query = payload[:sql]
      next unless query.include?('follow_import_targets')
      next unless query.include?('SELECT')
      next if query.match?(/COUNT/i)

      target_row_selects << query
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.new(batch_scope: FollowImportBatch.shadow_planning_scope)
                     .owner_work(cursor: FollowImport::FairnessCursor::State.empty)
    end

    expect(target_row_selects).to all(include('DISTINCT'))
    expect(target_row_selects).not_to include(a_string_matching(/LIMIT/i))
  end
end
