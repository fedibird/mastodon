# frozen_string_literal: true

# Backstop for approved account migrations whose MoveService completion
# marker is still empty. The enqueue after approval can be lost. This
# pass re-enqueues AccountMigration::ActionReviewExecutionWorker. It does
# not decide policy. The pass is bounded because a stuck row must not
# turn into a full-table scan.
class Scheduler::AccountMigrationActionReviewExecutionScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT = 100

  def perform
    unfinished_requests.limit(BATCH_LIMIT).each do |request|
      AccountMigration::ActionReviewExecutionWorker.perform_async(request.id)
    end
  end

  private

  def unfinished_requests
    ActionReviewRequest
      .approved_state
      .where(operation_type: 'account_migration', resource_type: 'AccountMigration')
      .joins('INNER JOIN account_migrations ON account_migrations.id = action_review_requests.resource_id')
      .where(account_migrations: { action_review_executed_at: nil })
      .order('action_review_requests.id ASC')
  end
end
