# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe ExternalSubscriptionDeletion do
  def build(attributes = {})
    described_class.new({ user_id: 1, external_subscription_id: 1, external_source_id: 1, requested_at: Time.current }.merge(attributes))
  end

  it 'is preparing until the first count is known and has no percent or remaining' do
    deletion = build
    expect(deletion).to be_preparing
    expect(deletion.percent).to be_nil
    expect(deletion.remaining).to be_nil
    expect(deletion.eta_seconds).to be_nil
  end

  it 'derives remaining and percent from the deleted rows' do
    deletion = build(state: 'running', total_count: 200, deleted_count: 50)
    expect(deletion).not_to be_preparing
    expect(deletion.remaining).to eq 150
    expect(deletion.percent).to eq 25
  end

  it 'never reaches 100 percent before it is completed' do
    expect(build(state: 'running', total_count: 1000, deleted_count: 999).percent).to eq 99
    expect(build(state: 'running', total_count: 0, deleted_count: 0).percent).to eq 99
    expect(build(state: 'failed', total_count: 0, deleted_count: 0, next_run_at: 1.minute.from_now).percent).to eq 99
    expect(build(state: 'completed', total_count: 10, deleted_count: 10).percent).to eq 100
  end

  it 'clamps remaining at zero when more rows went than were counted' do
    expect(build(state: 'running', total_count: 5, deleted_count: 8).remaining).to eq 0
  end

  it 'gives an estimate only for a running job with an observed speed' do
    now = Time.current
    base = { state: 'running', total_count: 100, deleted_count: 40, started_at: now - 20, last_progress_at: now }
    expect(build(base).eta_seconds).to eq 30
    expect(build(base.merge(started_at: now - 1)).eta_seconds).to be_nil
    expect(build(base.merge(deleted_count: 0)).eta_seconds).to be_nil
    expect(build(base.merge(state: 'failed')).eta_seconds).to be_nil
    expect(build(base.merge(state: 'queued')).eta_seconds).to be_nil
    expect(build(base.merge(total_count: nil)).eta_seconds).to be_nil
  end

  it 'tells an automatic retry from a failure that waits for the owner' do
    waiting = build(state: 'failed', next_run_at: 5.minutes.from_now)
    exhausted = build(state: 'failed', next_run_at: nil)

    expect(waiting).to be_auto_retrying
    expect(waiting).to be_in_flight
    expect(waiting.retryable?).to be false
    expect(waiting).not_to be_terminal_failed
    expect(exhausted).not_to be_auto_retrying
    expect(exhausted).not_to be_in_flight
    expect(exhausted.retryable?).to be true
    expect(exhausted).to be_terminal_failed
    expect(build(state: 'queued')).to be_in_flight
    expect(build(state: 'completed')).not_to be_in_flight
  end

  it 'allows only the four states' do
    queued = build(state: 'queued')
    queued.valid?
    expect(queued.errors[:state]).to be_empty
    other = build(state: 'deleting')
    other.valid?
    expect(other.errors[:state]).not_to be_empty
  end
end

RSpec.describe ExternalSubscriptionDeletion, 'settings visibility and dismiss' do
  def persist(owner, attributes = {})
    @subscription_seq = (@subscription_seq || 9_400_000_000) + 1
    described_class.create!(
      {
        user: owner,
        external_subscription_id: @subscription_seq,
        external_source_id: @subscription_seq,
        state: 'completed',
        requested_at: Time.current,
        finished_at: Time.current,
        route_targets: [],
      }.merge(attributes)
    )
  end

  it 'uses the same 24 hour boundary in the query and on a loaded row' do
    owner = Fabricate(:user)
    other = Fabricate(:user)
    now = Time.zone.parse('2026-10-28 12:00:00')

    travel_to(now) do
      shown = persist(owner, finished_at: now - 23.hours - 59.minutes)
      boundary = persist(owner, finished_at: now - 24.hours)
      older = persist(owner, finished_at: now - 24.hours - 1.second)
      dismissed = persist(owner, finished_at: now - 1.hour, dismissed_at: now - 1.minute)
      failed = persist(owner, state: 'failed', finished_at: now - 10.days, next_run_at: nil)
      waiting = persist(owner, state: 'failed', finished_at: nil, next_run_at: now + 5.minutes)
      running = persist(owner, state: 'running', finished_at: nil, requested_at: now - 3.days)
      queued = persist(owner, state: 'queued', finished_at: nil, requested_at: now - 3.days)
      theirs = persist(other, finished_at: now - 1.hour)
      rows = [shown, boundary, older, dismissed, failed, waiting, running, queued]

      visible_ids = described_class.settings_visible(now).where(user_id: owner.id).order(:id).pluck(:id)
      expect(visible_ids).to eq(rows.select { |row| row.settings_visible?(now) }.map(&:id))
      expect(visible_ids).to contain_exactly(shown.id, failed.id, waiting.id, running.id, queued.id)
      expect(visible_ids).not_to include(theirs.id)
      expect(described_class.exists?(boundary.id)).to be true
      expect(described_class.exists?(older.id)).to be true

      sql = described_class.settings_visible.where(user_id: owner.id).order(id: :desc).limit(ExternalServices::RSS::DELETION_LIMIT).to_sql
      expect(sql).to include('dismissed_at')
      expect(sql).to match(/LIMIT 10\b/)
      expect(sql.index('LIMIT')).to be > sql.index('WHERE')
    end
  end

  it 'closes only the owner completed row, once, and leaves the rest of the record' do
    owner = Fabricate(:user)
    roommate = Fabricate(:user)
    row = persist(owner, control_enqueued_at: Time.current, route_targets: [{ 'type' => 'home' }])
    effect = ExternalSubscriptionDeletionEffect.create!(external_subscription_deletion: row, status_id: row.id)

    expect(described_class.dismiss_for(user: owner, id: row.id)).to eq :dismissed
    row.reload
    stamp = row.dismissed_at
    expect(stamp).to be_within(2.seconds).of(Time.current)
    expect(row).to be_completed
    expect(row.control_enqueued_at).to be_present
    expect(row.route_targets).to eq [{ 'type' => 'home' }]
    expect(ExternalSubscriptionDeletionEffect.exists?(effect.id)).to be true

    expect(described_class.dismiss_for(user: owner, id: row.id)).to eq :already
    expect(row.reload.dismissed_at).to eq stamp

    running = persist(owner, state: 'running', finished_at: nil)
    expect(described_class.dismiss_for(user: owner, id: running.id)).to eq :not_completed
    expect(running.reload).to be_running
    expect(running.dismissed_at).to be_nil

    queued = persist(owner, state: 'queued', finished_at: nil)
    failed = persist(owner, state: 'failed', finished_at: 2.days.ago, next_run_at: 1.minute.from_now)
    exhausted = persist(owner, state: 'failed', finished_at: nil, next_run_at: nil)
    [queued, failed, exhausted].each do |open|
      expect(described_class.dismiss_for(user: owner, id: open.id)).to eq :not_completed
      expect(open.reload.dismissed_at).to be_nil
      expect(open.state).not_to eq 'completed'
    end

    expect(described_class.dismiss_for(user: roommate, id: row.id)).to eq :missing
    expect(described_class.dismiss_for(user: owner, id: 0)).to eq :missing
    expect(described_class.dismiss_for(user: nil, id: row.id)).to eq :missing
    expect(row.reload.dismissed_at).to eq stamp
  end

  it 'keeps a dismissed row for the removal notice and the 30 day cleanup' do
    owner = Fabricate(:user)
    young = persist(owner, requested_at: 1.hour.ago, finished_at: 1.hour.ago, dismissed_at: Time.current, control_enqueued_at: nil, route_targets: [])
    old = persist(owner, requested_at: 40.days.ago, finished_at: 31.days.ago, dismissed_at: 20.days.ago, control_enqueued_at: 31.days.ago, route_targets: [])

    expect(ExternalBridge::RSS::SubscriptionRemovedNotice.recover!).to eq 1
    expect(young.reload.control_enqueued_at).to be_present
    expect(young.dismissed_at).to be_present
    expect(old.reload.control_enqueued_at).to be_present

    Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler.new.perform

    expect(described_class.exists?(young.id)).to be true
    expect(described_class.exists?(old.id)).to be false
    expect(young.reload.dismissed_at).to be_present
  end
end

# rubocop:enable Metrics/BlockLength
