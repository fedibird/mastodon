# frozen_string_literal: true

# Bound per-item projection retries, and require a marker to point at a
# personal external projection. The stricter trigger stays in place on rollback.
class ExternalBridgeRetryFairnessAndMarkerGuard < ActiveRecord::Migration[6.1]
  # Freeze the historical guard rather than executing the current full schema:
  # ExternalBridge::Schema::DEFINITIONS_SQL now references external_feed_routes
  # (created in 20261023140000) and later tables, which do not exist yet.
  # The owner trigger and composite FKs were installed in 20261019180000.
  OWNER_GUARD_SQL = <<~SQL.freeze
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
  SQL

  def up
    safety_assured do
      add_column :external_projection_failures, :attempt_count, :integer, null: false, default: 0
      add_column :external_projection_failures, :next_attempt_at, :datetime
      execute OWNER_GUARD_SQL
    end
  end

  def down
    safety_assured do
      remove_column :external_projection_failures, :next_attempt_at
      remove_column :external_projection_failures, :attempt_count
    end
  end
end
