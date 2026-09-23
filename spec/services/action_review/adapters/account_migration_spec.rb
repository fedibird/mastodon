# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::Adapters::AccountMigration do # rubocop:disable Metrics/BlockLength
  let(:user) { Fabricate(:user, password: '12345678') }
  let(:reviewer) { user_with_role('Owner').account }

  def store_policy
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'account_migration' => 'always' }
    )
    Rails.cache.clear
  end

  def hold
    store_policy
    target = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])
    AccountMigration::CreateService.new.call(
      account: user.account,
      user: user,
      attributes: { acct: target.acct, current_password: '12345678' }
    )
  end

  def decide(request, verb, reviewer_account: reviewer)
    described_class.new.call(
      request: request,
      decision: verb,
      reviewer_account: reviewer_account,
      decision_note: nil
    )
  end

  before do
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async)
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'is registered and actionable for a valid pending migration' do
    created = hold

    expect(ActionReview::AdapterRegistry.registered?('account_migration')).to be true
    expect(described_class.actionable?(created.request)).to be true
    expect(ActionReview::AdapterRegistry.actionable?(created.request)).to be true
  end

  it 'is not actionable when the actor, resource, suspension, move, or backreference does not match' do
    created = hold
    request = created.request
    migration = created.migration

    request.update!(actor_account: Fabricate(:account))
    expect(described_class.actionable?(request.reload)).to be false

    request.update!(actor_account: user.account, resource_id: 0)
    expect(described_class.actionable?(request.reload)).to be false

    request.update!(resource_id: migration.id)
    user.account.update!(suspended_at: Time.now.utc)
    expect(described_class.actionable?(request.reload)).to be false

    user.account.update!(suspended_at: nil, moved_to_account: Fabricate(:account))
    expect(described_class.actionable?(request.reload)).to be false

    user.account.update!(moved_to_account: nil)
    migration.target_account.update!(also_known_as: [])
    expect(described_class.actionable?(request.reload)).to be false
  end

  it 'approves without calling MoveService inside the decision and enqueues execution after commit' do
    created = hold
    baseline = ApplicationRecord.connection.open_transactions
    depth = nil
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async) { depth = ApplicationRecord.connection.open_transactions }
    expect(MoveService).not_to receive(:new)

    expect(decide(created.request, 'approve')).to eq :approved

    expect(depth).to eq baseline
    expect(created.request.reload.approved_state?).to be true
    expect(user.account.reload.moved_to_account_id).to be_nil
    expect(ModerationAction.count).to eq 0
  end

  it 'rejects without moving the source account or creating a moderation action' do
    created = hold
    expect(MoveService).not_to receive(:new)

    expect(decide(created.request, 'reject')).to eq :rejected

    expect(created.request.reload.rejected_state?).to be true
    expect(user.account.reload.moved_to_account_id).to be_nil
    expect(ModerationAction.count).to eq 0
  end

  it 'treats a repeated approve or reject as harmless and rejects the opposite decision' do
    created = hold
    decide(created.request, 'approve')
    expect(AccountMigration::ActionReviewExecutionWorker).not_to receive(:perform_async)

    expect(decide(created.request.reload, 'approve')).to eq :already_approved
    expect { decide(created.request.reload, 'reject') }.to raise_error(ActionReview::DecisionError)

    created.migration.update_column(:created_at, 31.days.ago)
    stopped = hold
    decide(stopped.request, 'reject')
    expect(decide(stopped.request.reload, 'reject')).to eq :already_rejected
    expect { decide(stopped.request.reload, 'approve') }.to raise_error(ActionReview::DecisionError)
  end

  it 'leaves a cancelled request without controls and does not change it' do
    created = hold
    created.request.update!(state: :cancelled)

    expect(described_class.actionable?(created.request.reload)).to be false
    expect { decide(created.request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(created.request.reload.cancelled_state?).to be true
  end

  it 'keeps the approved row when the execution enqueue is lost' do
    created = hold
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async).and_raise(RuntimeError, 'enqueue lost')

    expect(decide(created.request, 'approve')).to eq :approved
    expect(created.request.reload.approved_state?).to be true
    expect(user.account.reload.moved_to_account_id).to be_nil
  end

  describe 'concurrent moderators' do
    self.use_transactional_tests = false

    after do
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
      ActionReviewRequest.where(operation_type: 'account_migration', actor_account_id: user.account.id).delete_all
      AccountMigration.where(account_id: user.account.id).delete_all
    end

    it 'lets exactly one terminal decision win' do
      created = hold
      other = user_with_role('Moderator').account
      start = Queue.new
      winners = Queue.new
      errors = Queue.new

      threads = [
        [reviewer.id, 'approve'],
        [other.id, 'reject'],
      ].map do |actor_id, verb|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            fresh = ActionReviewRequest.find(created.request.id)
            actor = Account.find(actor_id)
            decide(fresh, verb, reviewer_account: actor)
            winners << verb
          rescue ActionReview::DecisionError
            errors << verb
          rescue StandardError => e
            errors << "#{verb}:#{e.class}:#{e.message}"
          end
        end
      end

      2.times { start << true }
      threads.each { |thread| thread.join(10) }

      expect(threads.all?(&:stop?)).to be true
      expect(winners.size).to eq 1
      expect(errors.size).to eq 1
      expect(created.request.reload.pending_state?).to be false
      expect(user.account.reload.moved_to_account_id).to be_nil
    end
  end
end
