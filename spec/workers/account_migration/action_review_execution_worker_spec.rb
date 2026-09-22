# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountMigration::ActionReviewExecutionWorker do # rubocop:disable Metrics/BlockLength
  let(:user) { Fabricate(:user, password: '12345678') }

  def hold
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'account_migration' => 'always' }
    )
    Rails.cache.clear
    target = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])
    AccountMigration::CreateService.new.call(
      account: user.account,
      user: user,
      attributes: { acct: target.acct, current_password: '12345678' }
    )
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'calls MoveService once under the migration lock and stamps executed_at' do
    created = hold
    created.request.update!(state: :approved, reviewed_at: Time.now.utc, reviewer_account: Fabricate(:account))
    move = instance_double(MoveService, call: true)
    allow(MoveService).to receive(:new).and_return(move)
    locked = nil
    allow_any_instance_of(AccountMigration).to receive(:with_redis_lock).and_wrap_original do |method, name, &block|
      locked = name
      method.call(name, &block)
    end

    described_class.new.perform(created.request.id)
    described_class.new.perform(created.request.id)

    expect(locked).to eq "account_migration_action_review:#{created.migration.id}"
    expect(move).to have_received(:call).with(created.migration).once
    expect(created.migration.reload.action_review_executed_at).to be_present
  end

  it 'leaves executed_at empty when MoveService fails' do
    created = hold
    created.request.update!(state: :approved, reviewed_at: Time.now.utc, reviewer_account: Fabricate(:account))
    failing = instance_double(MoveService)
    allow(failing).to receive(:call).and_raise(RuntimeError, 'move failed')
    allow(MoveService).to receive(:new).and_return(failing)

    expect { described_class.new.perform(created.request.id) }.to raise_error(RuntimeError, 'move failed')
    expect(created.migration.reload.action_review_executed_at).to be_nil
  end

  it 'does not move a source account that already points somewhere else' do
    created = hold
    created.request.update!(state: :approved, reviewed_at: Time.now.utc, reviewer_account: Fabricate(:account))
    user.account.update!(moved_to_account: Fabricate(:account))
    expect(MoveService).not_to receive(:new)

    described_class.new.perform(created.request.id)

    expect(created.migration.reload.action_review_executed_at).to be_nil
  end

  it 'ignores a request that is not an approved account migration' do
    created = hold
    expect(MoveService).not_to receive(:new)

    described_class.new.perform(created.request.id)

    expect(created.migration.reload.action_review_executed_at).to be_nil
  end
end
