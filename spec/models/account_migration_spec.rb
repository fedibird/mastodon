# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountMigration, type: :model do
  let(:source) { Fabricate(:account) }

  def target_for(account)
    Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(account)])
  end

  def migrate_to(account, target)
    account.migrations.create!(acct: target.acct)
  end

  def review_for(migration, state:)
    ActionReviewRequest.create!(
      operation_type: 'account_migration',
      state: state,
      actor_account: migration.account,
      resource: migration,
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: { 'schema_version' => 1 },
      requested_at: Time.now.utc
    )
  end

  it 'counts an ordinary recent migration as cooldown' do
    migrate_to(source, target_for(source))

    expect(source.migrations.within_cooldown.exists?).to be true
  end

  it 'counts a pending reviewed migration as cooldown' do
    migration = migrate_to(source, target_for(source))
    review_for(migration, state: :pending)

    expect(source.migrations.within_cooldown.exists?).to be true
  end

  it 'counts an approved reviewed migration as cooldown' do
    migration = migrate_to(source, target_for(source))
    review_for(migration, state: :approved)

    expect(source.migrations.within_cooldown.exists?).to be true
  end

  it 'does not count a rejected reviewed migration as cooldown' do
    migration = migrate_to(source, target_for(source))
    review_for(migration, state: :rejected)

    expect(source.migrations.within_cooldown.exists?).to be false
  end

  it 'does not count a cancelled reviewed migration as cooldown' do
    migration = migrate_to(source, target_for(source))
    review_for(migration, state: :cancelled)

    expect(source.migrations.within_cooldown.exists?).to be false
  end
end
