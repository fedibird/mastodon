# frozen_string_literal: true

# E2 permits one transition, visibility 200 to 201, for a single projection
# status inside the transaction that calls external_visibility_migrate_status.
# It does not edit the E1 migration, does not drop foreign keys, does not add
# a statuses column or index, and does not rewrite existing rows.
#
# up replaces two functions. It does not recreate triggers: visibility is
# already in the field-guard UPDATE OF list. Replacing a function does not
# rewrite statuses. lock_timeout is 5s so a busy catalog fails instead of waiting.
#
# down removes that permit and restores the E1 field guard. External rows may
# remain. Down does not convert them back to personal and does not return the
# database to a pre-E1 guard. Code older than E1 cannot read visibility 201.
class PermitExternalVisibilityProjectionTransition < ActiveRecord::Migration[6.1]
  # Fixed E1 field guard. Do not read ExternalBridge::Schema here: a later edit
  # to the current guard must not change what this revision rolls back to.
  DOWN_FIELD_GUARD_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION statuses_external_projection_field_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.external_projection IS TRUE
         OR NEW.external_projection IS TRUE
         OR OLD.visibility = 201
         OR NEW.visibility = 201
         OR EXISTS (SELECT 1 FROM external_status_projections WHERE status_id = OLD.id) THEN
        IF NEW.account_id IS DISTINCT FROM OLD.account_id
           OR NEW.visibility IS DISTINCT FROM OLD.visibility
           OR NEW.searchability IS DISTINCT FROM OLD.searchability
           OR NEW.uri IS DISTINCT FROM OLD.uri
           OR NEW.external_projection IS DISTINCT FROM TRUE
           OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
           OR NEW.reblog_of_id IS DISTINCT FROM OLD.reblog_of_id
           OR NEW.in_reply_to_id IS DISTINCT FROM OLD.in_reply_to_id
           OR NEW.quote_id IS DISTINCT FROM OLD.quote_id
           OR (
             (OLD.visibility = 201 OR NEW.visibility = 201)
             AND (
               NEW.local IS DISTINCT FROM OLD.local
               OR NEW.reply IS DISTINCT FROM OLD.reply
             )
           ) THEN
          RAISE EXCEPTION 'external projection status fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$;

    DROP FUNCTION IF EXISTS external_visibility_migrate_status(bigint);
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute ExternalBridge::Schema::FIELD_GUARD_FUNCTION_SQL
      execute ExternalBridge::Schema::MIGRATE_FUNCTION_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute DOWN_FIELD_GUARD_SQL
    end
  end
end
