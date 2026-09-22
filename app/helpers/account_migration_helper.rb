# frozen_string_literal: true

module AccountMigrationHelper
  def migration_review(migration)
    return if migration.nil?

    reviews = instance_variable_get(:@migration_reviews)
    return if reviews.nil?

    reviews[migration.id]
  end

  # No review means the historical immediate path. Rejected and cancelled
  # both stay stopped for the account owner. Moderator notes stay off this page.
  def account_migration_workflow_label(migration, review = migration_review(migration))
    return t('migrations.review.moved') if review.nil?
    return t('migrations.review.waiting') if review.pending_state?
    return approved_label(migration) if review.approved_state?

    t('migrations.review.stopped')
  end

  private

  def approved_label(migration)
    if migration.action_review_executed_at.present?
      t('migrations.review.moved')
    else
      t('migrations.review.processing')
    end
  end
end
