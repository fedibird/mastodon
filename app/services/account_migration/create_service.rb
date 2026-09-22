# frozen_string_literal: true

# Starts an account migration after the existing password or username challenge.
#
# off keeps today's behavior: save the row, then MoveService immediately.
# always saves the row and a pending Action Review request together, and
# does not call MoveService. There is no migration classifier. signal_level
# stays none. Challenge values are not stored on the review.
class AccountMigration::CreateService
  EVIDENCE_SCHEMA_VERSION = 1

  Result = Struct.new(:migration, :request, :status, keyword_init: true) do
    def moved?
      status == :moved
    end

    def pending_review?
      status == :pending_review
    end

    def invalid?
      status == :invalid
    end
  end

  def call(account:, user:, attributes:)
    migration = account.migrations.build(attributes)
    decision = ActionReview::PolicyDecisionService.new.call(
      operation_type: 'account_migration',
      signal_level: 'none',
      evaluation_status: 'ok'
    )

    if decision.requires_review?
      hold(migration, user, decision)
    else
      move_now(migration, user)
    end
  end

  private

  def move_now(migration, user)
    return invalid(migration) unless migration.save_with_challenge(user)

    MoveService.new.call(migration)
    Result.new(migration: migration, request: nil, status: :moved)
  end

  def hold(migration, user, decision)
    as_of = Time.now.utc
    request = nil
    saved = false

    ApplicationRecord.transaction do
      saved = migration.save_with_challenge(user)
      raise ActiveRecord::Rollback unless saved

      request = record_request!(migration, user, decision, as_of)
      raise ActiveRecord::Rollback if request.nil?
    end

    return invalid(migration) unless saved
    raise ActiveRecord::RecordNotSaved, 'account migration review was not recorded' if request.nil?

    Result.new(migration: migration, request: request, status: :pending_review)
  end

  def record_request!(migration, user, decision, as_of)
    metrics = AccountMigration::ReviewMetricsService.new.call(migration.account, as_of: as_of)
    request = ActionReview::RequestService.new.call(
      operation_type: 'account_migration',
      actor_account: user.account,
      resource: migration,
      decision: decision,
      evidence: evidence_for(migration, metrics)
    ).request
    request&.update!(requested_at: as_of)
    request
  end

  def evidence_for(migration, metrics)
    {
      'schema_version' => EVIDENCE_SCHEMA_VERSION,
      'target_acct' => migration.acct,
      'followers_count_at_request' => migration.followers_count.to_i,
      'target_account_local' => migration.target_account.local?,
      'metrics' => metrics,
    }
  end

  def invalid(migration)
    Result.new(migration: migration, request: nil, status: :invalid)
  end
end
