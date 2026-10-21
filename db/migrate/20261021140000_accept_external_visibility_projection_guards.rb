# frozen_string_literal: true

# E1 accepts visibility 200 and 201 on projection markers and protects an
# external status at insert. It does not drop composite foreign keys, does not
# add a statuses index, and does not rewrite existing rows.
#
# The new BEFORE INSERT trigger needs ACCESS EXCLUSIVE on statuses. It does not
# rewrite the table. lock_timeout is 5s so a busy table fails this migration
# instead of waiting. Existing trigger objects stay; CREATE OR REPLACE FUNCTION
# updates their bodies.
#
# down restores the pre-E1 function bodies only when no visibility 201 row
# exists. Those bodies are fixed in this file. A database that already stores
# external statuses cannot silently return to the personal-only marker check.
class AcceptExternalVisibilityProjectionGuards < ActiveRecord::Migration[6.1]
  DOWN_PRECONDITION_SQL = <<~SQL
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM statuses WHERE visibility = 201) THEN
        RAISE EXCEPTION 'refusing to roll back external visibility guards while visibility 201 statuses exist'
          USING ERRCODE = 'check_violation';
      END IF;
    END $$;
  SQL

  # Fixed pre-E1 definitions. Do not read ExternalBridge::Schema here.
  DOWN_GUARD_SQL = <<~SQL
    CREATE OR REPLACE FUNCTION external_status_projections_enforce_owner_account()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      user_account_id bigint;
      status_account_id bigint;
      status_projection boolean;
      status_visibility integer;
    BEGIN
      IF TG_OP = 'UPDATE' AND (
        NEW.user_id IS DISTINCT FROM OLD.user_id OR
        NEW.account_id IS DISTINCT FROM OLD.account_id OR
        NEW.status_id IS DISTINCT FROM OLD.status_id
      ) THEN
        RAISE EXCEPTION 'external_status_projections identifiers are immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT account_id INTO user_account_id FROM users WHERE id = NEW.user_id FOR SHARE;
      SELECT account_id, external_projection, visibility
        INTO status_account_id, status_projection, status_visibility
        FROM statuses WHERE id = NEW.status_id FOR SHARE;

      IF status_projection IS NOT TRUE OR status_visibility IS DISTINCT FROM 200 THEN
        RAISE EXCEPTION 'external_status_projections require a personal external projection'
          USING ERRCODE = 'check_violation';
      END IF;

      IF user_account_id IS NULL
         OR status_account_id IS NULL
         OR user_account_id IS DISTINCT FROM NEW.account_id
         OR status_account_id IS DISTINCT FROM NEW.account_id THEN
        RAISE EXCEPTION 'external_status_projections account mismatch'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$;

    CREATE OR REPLACE FUNCTION statuses_external_projection_field_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.external_projection IS TRUE
         OR EXISTS (SELECT 1 FROM external_status_projections WHERE status_id = OLD.id) THEN
        IF NEW.account_id IS DISTINCT FROM OLD.account_id
           OR NEW.visibility IS DISTINCT FROM OLD.visibility
           OR NEW.searchability IS DISTINCT FROM OLD.searchability
           OR NEW.uri IS DISTINCT FROM OLD.uri
           OR NEW.external_projection IS DISTINCT FROM TRUE
           OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
           OR NEW.reblog_of_id IS DISTINCT FROM OLD.reblog_of_id
           OR NEW.in_reply_to_id IS DISTINCT FROM OLD.in_reply_to_id
           OR NEW.quote_id IS DISTINCT FROM OLD.quote_id THEN
          RAISE EXCEPTION 'external projection status fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$;

    DROP TRIGGER IF EXISTS statuses_external_visibility_shape_guard ON statuses;
    DROP FUNCTION IF EXISTS statuses_external_visibility_shape_guard();
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute ExternalBridge::Schema::GUARD_REFRESH_SQL
      execute ExternalBridge::Schema::SHAPE_TRIGGER_ATTACH_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute DOWN_PRECONDITION_SQL
      execute DOWN_GUARD_SQL
    end
  end
end
