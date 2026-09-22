# frozen_string_literal: true

# Runs MoveService after an account-migration review is approved.
#
# Execution is at-least-once. The ActivityPub Move activity id is
# deterministic from the migration id, so a repeated delivery is the
# same Move. A crash after MoveService returns and before
# action_review_executed_at is stored leaves the marker empty. This
# worker, or Scheduler::AccountMigrationActionReviewExecutionScheduler,
# can run again. MoveService is not called for a row that is already
# stamped, or when the source has moved somewhere else.
class AccountMigration::ActionReviewExecutionWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'default', retry: 5

  def perform(request_id)
    request = ActionReviewRequest.find_by(id: request_id)
    migration = executable_migration(request)
    return if migration.nil?

    migration.with_redis_lock("account_migration_action_review:#{migration.id}") do
      migration.reload
      request.reload
      return if migration.action_review_executed_at.present?
      return unless still_executable?(request, migration)

      MoveService.new.call(migration)
      # Skip validations. The migration row itself is inside the 30-day
      # cooldown, so a normal update would reject this completion stamp.
      migration.update_columns(action_review_executed_at: Time.now.utc)
    end
  end

  private

  def executable_migration(request)
    return if request.nil?
    return unless request.operation_type == 'account_migration'
    return unless request.approved_state?
    return unless request.resource_type == 'AccountMigration'

    migration = request.resource
    return unless migration.is_a?(::AccountMigration) && migration.id == request.resource_id
    return if migration.action_review_executed_at.present?
    return unless still_executable?(request, migration)

    migration
  end

  def still_executable?(request, migration)
    ActionReview::Adapters::AccountMigration.consistent?(request, migration)
  end
end
