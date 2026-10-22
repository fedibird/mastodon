# frozen_string_literal: true

# Databases that already applied 20261021180000 from an earlier draft still
# have CREATE FUNCTION ... SET fedibird.external_visibility_migration. That
# clause cannot be installed by a normal database owner. Replace the function
# in place. Do not rewrite statuses, do not edit the E1 migration, and do not
# restore the SET clause on the way down.
class ReinstallExternalVisibilityMigrateFunction < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute ExternalBridge::Schema::MIGRATE_FUNCTION_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute ExternalBridge::Schema::MIGRATE_FUNCTION_SQL
    end
  end
end
