# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::AccountMigrationActionReviewExecutionScheduler do
  def approved_migration(executed_at: nil)
    source = Fabricate(:account)
    target = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(source)])
    migration = source.migrations.new(acct: target.acct)
    migration.save!(validate: false)
    migration.update_column(:action_review_executed_at, executed_at) if executed_at
    request = ActionReviewRequest.create!(
      operation_type: 'account_migration',
      state: :approved,
      actor_account: source,
      resource: migration,
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: { 'schema_version' => 1 },
      requested_at: Time.now.utc,
      reviewed_at: Time.now.utc
    )
    [migration, request]
  end

  it 'enqueues approved migrations that have not been executed' do
    _first_migration, first_request = approved_migration
    _done_migration, done_request = approved_migration(executed_at: Time.now.utc)
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async)

    described_class.new.perform

    expect(AccountMigration::ActionReviewExecutionWorker).to have_received(:perform_async).with(first_request.id)
    expect(AccountMigration::ActionReviewExecutionWorker).not_to have_received(:perform_async).with(done_request.id)
  end

  it 'stops at the batch limit' do
    approved_migration
    approved_migration
    stub_const("#{described_class}::BATCH_LIMIT", 1)
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async)

    described_class.new.perform

    expect(AccountMigration::ActionReviewExecutionWorker).to have_received(:perform_async).once
  end
end
