# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountMigration::CreateService do # rubocop:disable Metrics/BlockLength
  let(:user) { Fabricate(:user, password: '12345678') }
  let(:source) { user.account }

  def target_for(account = source)
    Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(account)])
  end

  def store_policy(mode)
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'account_migration' => mode }
    )
    Rails.cache.clear
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  def call(attributes)
    described_class.new.call(account: source, user: user, attributes: attributes)
  end

  it 'saves and moves immediately when policy is off' do
    store_policy('off')
    target = target_for
    expect(MoveService).to receive(:new).and_call_original

    result = call(acct: target.acct, current_password: '12345678')

    expect(result.moved?).to be true
    expect(result.request).to be_nil
    expect(ActionReviewRequest.count).to eq 0
    expect(source.reload.moved_to_account_id).to eq target.id
  end

  it 'persists a pending review and does not call MoveService when policy is always' do
    store_policy('always')
    target = target_for
    expect(MoveService).not_to receive(:new)

    result = call(acct: target.acct, current_password: '12345678')

    expect(result.pending_review?).to be true
    expect(result.request.pending_state?).to be true
    expect(result.request.signal_level).to eq 'none'
    expect(result.request.operation_type).to eq 'account_migration'
    expect(result.request.resource).to eq result.migration
    expect(source.reload.moved_to_account_id).to be_nil
  end

  it 'stores the request-time metrics snapshot and no challenge material' do
    store_policy('always')
    target = target_for

    result = call(acct: target.acct, current_password: '12345678')
    evidence = result.request.evidence

    expect(evidence.keys).to contain_exactly(
      'schema_version',
      'target_acct',
      'followers_count_at_request',
      'target_account_local',
      'metrics'
    )
    expect(evidence['target_acct']).to eq target.acct
    expect(evidence['followers_count_at_request']).to eq result.migration.followers_count
    expect(evidence['metrics']['as_of']).to be_present
    expect(Time.iso8601(evidence['metrics']['as_of']).to_i).to eq result.request.requested_at.to_i
    expect(evidence.to_json).not_to include('12345678')
    expect(evidence.to_json).not_to include('current_password')
  end

  it 'returns invalid and persists nothing when the challenge fails' do
    store_policy('always')

    result = call(acct: target_for.acct, current_password: 'wrong-password')

    expect(result.invalid?).to be true
    expect(AccountMigration.count).to eq 0
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'returns invalid and persists nothing when the migration is not valid' do
    store_policy('always')

    result = call(acct: source.acct, current_password: '12345678')

    expect(result.invalid?).to be true
    expect(result.migration.errors).to be_present
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'rolls the migration back when the review row cannot be saved' do
    store_policy('always')
    allow(ActionReviewRequest).to receive(:create!).and_raise(ActiveRecord::StatementInvalid)

    expect { call(acct: target_for.acct, current_password: '12345678') }.to raise_error(ActiveRecord::StatementInvalid)
    expect(AccountMigration.count).to eq 0
    expect(ActionReviewRequest.count).to eq 0
  end
end
