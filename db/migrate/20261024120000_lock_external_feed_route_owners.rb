# frozen_string_literal: true

# Serialize a route insert with an uncommitted account move, and keep a
# route's user attached to the same account when that user has no projection.
# Replaces two function bodies. It does not rewrite rows or add indexes.
class LockExternalFeedRouteOwners < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute <<~SQL
        CREATE OR REPLACE FUNCTION external_feed_routes_enforce_list_owner()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        DECLARE
          owner_account_id bigint;
          list_account_id bigint;
        BEGIN
          IF NEW.destination = 'list' THEN
            SELECT account_id INTO owner_account_id FROM users WHERE id = NEW.user_id FOR SHARE;
            SELECT account_id INTO list_account_id FROM lists WHERE id = NEW.list_id FOR SHARE;
            IF owner_account_id IS NULL
               OR list_account_id IS NULL
               OR owner_account_id IS DISTINCT FROM list_account_id THEN
              RAISE EXCEPTION 'external feed route list is not owned by the user account'
                USING ERRCODE = 'check_violation';
            END IF;
          END IF;

          RETURN NEW;
        END;
        $$;

        CREATE OR REPLACE FUNCTION users_external_projection_account_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF NEW.account_id IS DISTINCT FROM OLD.account_id
             AND (
               EXISTS (SELECT 1 FROM external_status_projections WHERE user_id = OLD.id)
               OR EXISTS (SELECT 1 FROM external_feed_routes WHERE user_id = OLD.id)
             ) THEN
            RAISE EXCEPTION 'users.account_id cannot change while an external projection or feed route exists'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$;
      SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute <<~SQL
        CREATE OR REPLACE FUNCTION external_feed_routes_enforce_list_owner()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        DECLARE
          owner_account_id bigint;
          list_account_id bigint;
        BEGIN
          IF NEW.destination = 'list' THEN
            SELECT account_id INTO owner_account_id FROM users WHERE id = NEW.user_id;
            SELECT account_id INTO list_account_id FROM lists WHERE id = NEW.list_id;
            IF owner_account_id IS NULL
               OR list_account_id IS NULL
               OR owner_account_id IS DISTINCT FROM list_account_id THEN
              RAISE EXCEPTION 'external feed route list is not owned by the user account'
                USING ERRCODE = 'check_violation';
            END IF;
          END IF;

          RETURN NEW;
        END;
        $$;

        CREATE OR REPLACE FUNCTION users_external_projection_account_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF NEW.account_id IS DISTINCT FROM OLD.account_id
             AND EXISTS (SELECT 1 FROM external_status_projections WHERE user_id = OLD.id) THEN
            RAISE EXCEPTION 'users.account_id cannot change while projections exist'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$;
      SQL
    end
  end
end
