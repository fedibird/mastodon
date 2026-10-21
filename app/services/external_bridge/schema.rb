# frozen_string_literal: true

module ExternalBridge
  # Rails 6.1 schema dump does not emit triggers or composite foreign keys.
  # schema.rb and a schema dumper hook both execute this SQL so schema:load
  # keeps the projection guards. The statements are idempotent.
  #
  # db:schema:dump and db:schema:load do not boot the application on their own.
  # lib/tasks/external_bridge_schema.rake adds the :environment prerequisite so
  # this constant and the dumper hook exist before those tasks run.
  module Schema # rubocop:disable Metrics/ModuleLength -- trigger SQL is the schema:load contract
    # Status.visibilities[:personal] and Status.searchabilities[:personal].
    # Numeric so schema:load does not need the model. external is visibility
    # only; searchability stays personal. Numeric order is not authorization.
    PERSONAL_VISIBILITY = 200
    PERSONAL_SEARCHABILITY = 200
    EXTERNAL_VISIBILITY = 201

    # E2 field guard. A matching GUC is not permission by itself: the row must
    # be the named status, 200 to 201 only, and unchanged apart from visibility
    # and updated_at. schema:load installs this body. The E1 migration constant
    # below stays the pre-transition guard.
    FIELD_GUARD_FUNCTION_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION statuses_external_projection_field_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        migration_token text;
        marker_user_id bigint;
        marker_account_id bigint;
        marker_source_id bigint;
        marker_subscription_id bigint;
        marker_resource_id bigint;
        user_account_id bigint;
        subscription_user_id bigint;
        subscription_source_id bigint;
        resource_source_id bigint;
        permitted_transition boolean := false;
      BEGIN
        IF OLD.external_projection IS TRUE
           OR NEW.external_projection IS TRUE
           OR OLD.visibility = #{EXTERNAL_VISIBILITY}
           OR NEW.visibility = #{EXTERNAL_VISIBILITY}
           OR EXISTS (SELECT 1 FROM external_status_projections WHERE status_id = OLD.id) THEN

          migration_token := current_setting('fedibird.external_visibility_migration', true);

          IF migration_token IS NOT NULL
             AND migration_token = (OLD.id::text || ':' || txid_current()::text)
             AND OLD.visibility = #{PERSONAL_VISIBILITY}
             AND NEW.visibility = #{EXTERNAL_VISIBILITY} THEN
            IF OLD.external_projection IS TRUE
               AND NEW.external_projection IS TRUE
               AND OLD.local IS TRUE
               AND NEW.local IS TRUE
               AND OLD.uri IS NULL
               AND NEW.uri IS NULL
               AND OLD.searchability = #{PERSONAL_SEARCHABILITY}
               AND NEW.searchability = #{PERSONAL_SEARCHABILITY}
               AND OLD.reply IS NOT TRUE
               AND NEW.reply IS NOT TRUE
               AND OLD.in_reply_to_id IS NULL
               AND NEW.in_reply_to_id IS NULL
               AND OLD.reblog_of_id IS NULL
               AND NEW.reblog_of_id IS NULL
               AND OLD.quote_id IS NULL
               AND NEW.quote_id IS NULL
               AND OLD.deleted_at IS NULL
               AND NEW.deleted_at IS NULL
               AND (to_jsonb(OLD) - 'visibility' - 'updated_at')
                   IS NOT DISTINCT FROM
                   (to_jsonb(NEW) - 'visibility' - 'updated_at') THEN
              SELECT user_id, account_id, external_source_id, external_subscription_id, external_resource_id
                INTO marker_user_id, marker_account_id, marker_source_id, marker_subscription_id, marker_resource_id
              FROM external_status_projections
              WHERE status_id = OLD.id
              FOR SHARE;

              IF FOUND THEN
                SELECT account_id INTO user_account_id
                FROM users
                WHERE id = marker_user_id
                FOR SHARE;

                SELECT user_id, external_source_id
                  INTO subscription_user_id, subscription_source_id
                FROM external_subscriptions
                WHERE id = marker_subscription_id
                FOR SHARE;

                SELECT external_source_id INTO resource_source_id
                FROM external_resources
                WHERE id = marker_resource_id
                FOR SHARE;

                IF user_account_id IS NOT NULL
                   AND user_account_id = OLD.account_id
                   AND marker_account_id = OLD.account_id
                   AND subscription_user_id = marker_user_id
                   AND subscription_source_id = marker_source_id
                   AND resource_source_id = marker_source_id THEN
                  permitted_transition := true;
                END IF;
              END IF;
            END IF;
          END IF;

          IF NOT permitted_transition THEN
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
                 (OLD.visibility = #{EXTERNAL_VISIBILITY} OR NEW.visibility = #{EXTERNAL_VISIBILITY})
                 AND (
                   NEW.local IS DISTINCT FROM OLD.local
                   OR NEW.reply IS DISTINCT FROM OLD.reply
                 )
               ) THEN
              RAISE EXCEPTION 'external projection status fields are immutable'
                USING ERRCODE = 'check_violation';
            END IF;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    # Runs the visibility UPDATE and clears the permit when the function
    # returns, including when the caller is inside an outer transaction.
    # PostgreSQL restores the function's SET clause on exit, so SET LOCAL
    # made here does not survive the call. The trigger still rechecks the row.
    MIGRATE_FUNCTION_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION external_visibility_migrate_status(p_status_id bigint)
      RETURNS integer
      LANGUAGE plpgsql
      SET fedibird.external_visibility_migration TO 'off'
      AS $$
      DECLARE
        updated_count integer;
        token text;
      BEGIN
        token := p_status_id::text || ':' || txid_current()::text;
        PERFORM set_config('fedibird.external_visibility_migration', token, true);
        UPDATE statuses
           SET visibility = #{EXTERNAL_VISIBILITY},
               updated_at = clock_timestamp()
         WHERE id = p_status_id
           AND visibility = #{PERSONAL_VISIBILITY};
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        PERFORM set_config('fedibird.external_visibility_migration', 'off', true);
        RETURN updated_count;
      END;
      $$;
    SQL

    DEFINITIONS_SQL = <<~SQL
      ALTER TABLE external_status_projections
        DROP CONSTRAINT IF EXISTS fk_external_projections_subscription_owner;
      ALTER TABLE external_status_projections
        ADD CONSTRAINT fk_external_projections_subscription_owner
        FOREIGN KEY (external_subscription_id, user_id, external_source_id)
        REFERENCES external_subscriptions (id, user_id, external_source_id);

      ALTER TABLE external_status_projections
        DROP CONSTRAINT IF EXISTS fk_external_projections_resource_source;
      ALTER TABLE external_status_projections
        ADD CONSTRAINT fk_external_projections_resource_source
        FOREIGN KEY (external_resource_id, external_source_id)
        REFERENCES external_resources (id, external_source_id);

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

        IF status_projection IS NOT TRUE OR status_visibility NOT IN (#{PERSONAL_VISIBILITY}, #{EXTERNAL_VISIBILITY}) THEN
          RAISE EXCEPTION 'external_status_projections require a personal or external projection'
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
      DROP TRIGGER IF EXISTS external_status_projections_user_account ON external_status_projections;
      CREATE TRIGGER external_status_projections_user_account
      BEFORE INSERT OR UPDATE OF user_id, account_id, status_id
      ON external_status_projections
      FOR EACH ROW
      EXECUTE FUNCTION external_status_projections_enforce_owner_account();

      CREATE OR REPLACE FUNCTION external_status_projections_guard_delete()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF current_setting('fedibird.projection_status_delete', true) IS DISTINCT FROM 'on' THEN
          IF EXISTS (SELECT 1 FROM statuses WHERE id = OLD.status_id) THEN
            RAISE EXCEPTION 'external status projection cannot be deleted while its status exists'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN OLD;
      END;
      $$;
      DROP TRIGGER IF EXISTS external_status_projections_guard_delete ON external_status_projections;
      CREATE TRIGGER external_status_projections_guard_delete
      BEFORE DELETE ON external_status_projections
      FOR EACH ROW
      EXECUTE FUNCTION external_status_projections_guard_delete();

      #{FIELD_GUARD_FUNCTION_SQL}
      DROP TRIGGER IF EXISTS statuses_external_projection_field_guard ON statuses;
      CREATE TRIGGER statuses_external_projection_field_guard
      BEFORE UPDATE OF account_id, visibility, searchability, uri, external_projection, deleted_at, reblog_of_id, in_reply_to_id, quote_id, local, reply
      ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_projection_field_guard();

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
      DROP TRIGGER IF EXISTS users_external_projection_account_guard ON users;
      CREATE TRIGGER users_external_projection_account_guard
      BEFORE UPDATE OF account_id ON users
      FOR EACH ROW
      EXECUTE FUNCTION users_external_projection_account_guard();

      CREATE OR REPLACE FUNCTION statuses_external_visibility_shape_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.visibility = #{EXTERNAL_VISIBILITY} THEN
          IF NEW.external_projection IS NOT TRUE
             OR NEW.uri IS NOT NULL
             OR NEW.searchability IS DISTINCT FROM #{PERSONAL_SEARCHABILITY}
             OR NEW.local IS DISTINCT FROM TRUE
             OR NEW.reblog_of_id IS NOT NULL
             OR NEW.in_reply_to_id IS NOT NULL
             OR NEW.quote_id IS NOT NULL
             OR NEW.reply IS TRUE
             OR NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'external visibility status shape is invalid'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS statuses_external_visibility_shape_guard ON statuses;
      CREATE TRIGGER statuses_external_visibility_shape_guard
      BEFORE INSERT OR UPDATE OF local, reply ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_visibility_shape_guard();

      #{MIGRATE_FUNCTION_SQL}
    SQL

    # Migration up runs these statements only. schema:load uses DEFINITIONS_SQL,
    # which also reinstalls the composite foreign keys. Do not execute
    # DEFINITIONS_SQL against a populated database.
    GUARD_REFRESH_SQL = <<~SQL
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

        IF status_projection IS NOT TRUE OR status_visibility NOT IN (#{PERSONAL_VISIBILITY}, #{EXTERNAL_VISIBILITY}) THEN
          RAISE EXCEPTION 'external_status_projections require a personal or external projection'
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
           OR NEW.external_projection IS TRUE
           OR OLD.visibility = #{EXTERNAL_VISIBILITY}
           OR NEW.visibility = #{EXTERNAL_VISIBILITY}
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
               (OLD.visibility = #{EXTERNAL_VISIBILITY} OR NEW.visibility = #{EXTERNAL_VISIBILITY})
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

      CREATE OR REPLACE FUNCTION statuses_external_visibility_shape_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.visibility = #{EXTERNAL_VISIBILITY} THEN
          IF NEW.external_projection IS NOT TRUE
             OR NEW.uri IS NOT NULL
             OR NEW.searchability IS DISTINCT FROM #{PERSONAL_SEARCHABILITY}
             OR NEW.local IS DISTINCT FROM TRUE
             OR NEW.reblog_of_id IS NOT NULL
             OR NEW.in_reply_to_id IS NOT NULL
             OR NEW.quote_id IS NOT NULL
             OR NEW.reply IS TRUE
             OR NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'external visibility status shape is invalid'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    # CREATE OR REPLACE FUNCTION does not change an existing trigger's
    # UPDATE OF list. Replacing these two triggers takes ACCESS EXCLUSIVE on
    # statuses and does not rewrite the table. The migration sets lock_timeout.
    # Other triggers and the composite foreign keys stay in place.
    FIELD_GUARD_TRIGGER_SQL = <<~SQL
      DROP TRIGGER IF EXISTS statuses_external_projection_field_guard ON statuses;
      CREATE TRIGGER statuses_external_projection_field_guard
      BEFORE UPDATE OF account_id, visibility, searchability, uri, external_projection, deleted_at, reblog_of_id, in_reply_to_id, quote_id, local, reply
      ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_projection_field_guard();
    SQL

    SHAPE_TRIGGER_ATTACH_SQL = <<~SQL
      DROP TRIGGER IF EXISTS statuses_external_visibility_shape_guard ON statuses;
      CREATE TRIGGER statuses_external_visibility_shape_guard
      BEFORE INSERT OR UPDATE OF local, reply ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_visibility_shape_guard();
    SQL
  end
end
