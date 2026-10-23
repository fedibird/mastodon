# frozen_string_literal: true

# Recovery cursor for an unpublished E4 reference.
#
# next_recovery_at NULL is an unvisited outbox row. A future value means a
# publish job was accepted and must not be pushed again until that time.
# Dropping this column forgets the cursor only. The mapping, the policy, and
# the reference Status stay, so this down does not use the rollback floor.
class AddExternalLinkReferenceNextRecoveryAt < ActiveRecord::Migration[6.1]
  INDEX_SQL = <<~SQL
    CREATE INDEX IF NOT EXISTS index_link_refs_on_unpublished_recovery
    ON external_projection_link_references (next_recovery_at ASC NULLS FIRST, id)
    WHERE published_at IS NULL
      AND state IN ('active', 'superseded')
      AND reference_status_id IS NOT NULL
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      unless column_exists?(:external_projection_link_references, :next_recovery_at)
        add_column :external_projection_link_references, :next_recovery_at, :datetime
      end
      execute INDEX_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute 'DROP INDEX IF EXISTS index_link_refs_on_unpublished_recovery'
      if column_exists?(:external_projection_link_references, :next_recovery_at)
        remove_column :external_projection_link_references, :next_recovery_at
      end
    end
  end
end
