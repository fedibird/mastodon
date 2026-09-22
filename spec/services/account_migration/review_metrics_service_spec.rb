# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountMigration::ReviewMetricsService do # rubocop:disable Metrics/BlockLength
  let(:source) { Fabricate(:account) }
  let(:as_of) { Time.utc(2026, 9, 22, 12, 0, 0) }

  def subject_for(account)
    ModerationSubject.for_account!(account)
  end

  def outgoing_follow(counterpart, occurred_at)
    ModerationInteractionEvent.create!(
      actor_subject: subject_for(source),
      target_subject: subject_for(counterpart),
      event_type: :follow,
      occurred_at: occurred_at,
      observed_at: occurred_at,
      metadata: {}
    )
  end

  def incoming_follow(counterpart, created_at)
    follow = Follow.create!(account: counterpart, target_account: source)
    Follow.where(id: follow.id).update_all(created_at: created_at)
    follow
  end

  def metrics
    described_class.new.call(source, as_of: as_of)
  end

  it 'includes the account snapshot counts' do
    result = metrics

    expect(result['followers_count']).to eq source.followers_count.to_i
    expect(result['following_count']).to eq source.following_count.to_i
    expect(result['statuses_count']).to eq source.statuses_count.to_i
    expect(result['account_age_seconds']).to be >= 0
    expect(result['as_of']).to eq as_of.iso8601
    expect(result['generated_at']).to eq as_of.iso8601
  end

  it 'returns zeros when the account is missing' do
    result = described_class.new.call(nil, as_of: as_of)

    expect(result['followers_count']).to eq 0
    expect(result['windows']['24h']['follows']).to eq 0
    expect(result['windows']['24h']['returned_follows_after_outgoing']).to eq 0
    expect(result['follow_import_context']['batch_count']).to eq 0
  end

  it 'counts a returned follow only after the observed outgoing follow' do
    counterpart = Fabricate(:account)
    outgoing_follow(counterpart, as_of - 20.minutes)
    incoming_follow(counterpart, as_of - 10.minutes)

    window = metrics['windows']['1h']
    expect(window['returned_follows_after_outgoing']).to eq 1
    expect(window['returned_follow_rate']).to eq 1.0
  end

  it 'does not count an incoming follow that happened before the outgoing follow' do
    counterpart = Fabricate(:account)
    incoming_follow(counterpart, as_of - 30.minutes)
    outgoing_follow(counterpart, as_of - 10.minutes)

    expect(metrics['windows']['1h']['returned_follows_after_outgoing']).to eq 0
    expect(metrics['windows']['1h']['returned_follow_rate']).to eq 0.0
  end

  it 'ignores follows and ledger rows after as_of' do
    counterpart = Fabricate(:account)
    outgoing_follow(counterpart, as_of + 5.minutes)
    incoming_follow(counterpart, as_of + 10.minutes)

    expect(metrics['windows']['7d']['returned_follows_after_outgoing']).to eq 0
    expect(metrics['windows']['7d']['follows']).to eq 0
  end

  it 'dedupes counterpart accounts in the returned-follow count and rate' do
    counterpart = Fabricate(:account)
    other = Fabricate(:account)
    outgoing_follow(counterpart, as_of - 40.minutes)
    outgoing_follow(counterpart, as_of - 30.minutes)
    outgoing_follow(other, as_of - 20.minutes)
    incoming_follow(counterpart, as_of - 15.minutes)

    window = metrics['windows']['1h']
    expect(window['returned_follows_after_outgoing']).to eq 1
    expect(window['returned_follow_rate']).to eq 0.5
  end

  it 'does not treat an unresolved follow-import target as a returned follow' do
    subject = subject_for(source)
    imported_at = as_of - 2.hours
    batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: imported_at,
      mode: :merge,
      target_count: 2,
      resolved_target_count: 1,
      unresolved_target_count: 1
    )
    resolved = Fabricate(:account)
    FollowImportTarget.create!(batch: batch, target_subject: subject_for(resolved), position: 0)
    FollowImportTarget.create!(batch: batch, target_key_hash: 'secret-target-hash', position: 1)
    incoming_follow(resolved, imported_at + 5.minutes)

    window = metrics['windows']['24h']
    expect(window['follow_import_batches']).to eq 1
    expect(window['follow_import_unique_resolved_targets']).to eq 1
    expect(window['follow_import_returned_follows']).to eq 1
    expect(window['follow_import_returned_follow_rate']).to eq 1.0
    expect(metrics.to_json).not_to include('secret-target-hash')
  end

  it 'uses the earliest in-window import when a target appears in more than one batch' do
    subject = subject_for(source)
    resolved = Fabricate(:account)
    earlier = as_of - 3.hours
    later = as_of - 30.minutes
    [earlier, later].each_with_index do |imported_at, index|
      batch = FollowImportBatch.create!(
        subject: subject,
        imported_at: imported_at,
        mode: :merge,
        target_count: 1,
        resolved_target_count: 1,
        unresolved_target_count: 0
      )
      FollowImportTarget.create!(batch: batch, target_subject: subject_for(resolved), position: index)
    end
    incoming_follow(resolved, as_of - 2.hours)

    expect(metrics['windows']['24h']['follow_import_unique_resolved_targets']).to eq 1
    expect(metrics['windows']['24h']['follow_import_returned_follows']).to eq 1
  end

  it 'does not count a follow import return that predates the import' do
    subject = subject_for(source)
    resolved = Fabricate(:account)
    imported_at = as_of - 1.hour
    batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: imported_at,
      mode: :merge,
      target_count: 1,
      resolved_target_count: 1,
      unresolved_target_count: 0
    )
    FollowImportTarget.create!(batch: batch, target_subject: subject_for(resolved), position: 0)
    incoming_follow(resolved, imported_at - 10.minutes)

    expect(metrics['windows']['24h']['follow_import_returned_follows']).to eq 0
  end

  it 'copies negative metrics from BehavioralMetricsService' do
    behavior = {
      'windows' => {
        '1h' => { 'qualified_negative_events' => 4, 'follows' => 2, 'qualified_negative_response_rate' => 0.25 },
        '24h' => {},
        '7d' => {},
      },
      'follow_import_context' => {
        'batch_count' => 3,
        'target_total' => 9,
        'resolved_target_total' => 8,
        'unresolved_target_total' => 1,
        'unresolved_target_ratio' => 1.0 / 9,
        'prior_relationship_known_targets' => 5,
        'latest_import_at' => as_of.iso8601,
      },
    }
    allow_any_instance_of(Moderation::BehavioralMetricsService).to receive(:call).and_return(behavior)

    result = metrics
    expect(result['windows']['1h']['qualified_negative_events']).to eq 4
    expect(result['windows']['1h']['qualified_negative_response_rate']).to eq 0.25
    expect(result['follow_import_context']['batch_count']).to eq 0
    expect(result['follow_import_context'].keys).not_to include('subject_id', 'account_id')
  end

  it 'keeps follow import context at or before as_of' do
    subject = subject_for(source)
    past = as_of - 1.hour
    future = as_of + 1.minute
    past_batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: past,
      mode: :merge,
      target_count: 4,
      resolved_target_count: 3,
      unresolved_target_count: 1
    )
    FollowImportTarget.create!(
      batch: past_batch,
      target_subject: subject_for(Fabricate(:account)),
      position: 0,
      prior_relationship_state: { 'following' => true }
    )
    future_batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: future,
      mode: :merge,
      target_count: 10,
      resolved_target_count: 8,
      unresolved_target_count: 2
    )
    2.times do |index|
      FollowImportTarget.create!(
        batch: future_batch,
        target_subject: subject_for(Fabricate(:account)),
        position: index,
        prior_relationship_state: { 'following' => true }
      )
    end

    context = metrics['follow_import_context']
    expect(context['batch_count']).to eq 1
    expect(context['target_total']).to eq 4
    expect(context['resolved_target_total']).to eq 3
    expect(context['unresolved_target_total']).to eq 1
    expect(context['unresolved_target_ratio']).to eq 0.25
    expect(context['prior_relationship_known_targets']).to eq 1
    expect(Time.iso8601(context['latest_import_at'])).to be <= as_of
    expect(Time.iso8601(context['latest_import_at'])).to be_within(1.second).of(past)
  end

  it 'does not put raw ids, hashes, or addresses in the payload' do
    counterpart = Fabricate(:account, username: 'hidden_target')
    outgoing_follow(counterpart, as_of - 10.minutes)
    dumped = metrics.to_json

    expect(dumped).not_to include('subject_id')
    expect(dumped).not_to include('account_id')
    expect(dumped).not_to include('target_key_hash')
    expect(dumped).not_to include('hidden_target')
    expect(dumped).not_to include('@')
  end
end
