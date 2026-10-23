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

    # Runs the visibility UPDATE. The permit is transaction-local and is put
    # back to the caller's previous value before the function returns. An
    # exception, including query cancel, restores that same value and raises
    # again. There is no CREATE FUNCTION SET clause: storing a custom GUC there
    # requires a superuser or SET privilege, which a normal database owner does
    # not have. set_config inside the body does not. Unset restores through
    # NULL; PostgreSQL then reports a custom placeholder as an empty string,
    # which is not an id:txid permit. The trigger still rechecks the row.
    MIGRATE_FUNCTION_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION external_visibility_migrate_status(p_status_id bigint)
      RETURNS integer
      LANGUAGE plpgsql
      AS $$
      DECLARE
        updated_count integer;
        token text;
        previous text;
      BEGIN
        previous := current_setting('fedibird.external_visibility_migration', true);
        token := p_status_id::text || ':' || txid_current()::text;
        PERFORM set_config('fedibird.external_visibility_migration', token, true);
        UPDATE statuses
           SET visibility = #{EXTERNAL_VISIBILITY},
               updated_at = clock_timestamp()
         WHERE id = p_status_id
           AND visibility = #{PERSONAL_VISIBILITY};
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        PERFORM set_config('fedibird.external_visibility_migration', previous, true);
        RETURN updated_count;
      EXCEPTION
        WHEN query_canceled THEN
          PERFORM set_config('fedibird.external_visibility_migration', previous, true);
          RAISE;
        WHEN OTHERS THEN
          PERFORM set_config('fedibird.external_visibility_migration', previous, true);
          RAISE;
      END;
      $$;
    SQL

    # Route shape and the subscription/user pair live in the migration and in
    # schema.rb. This SQL is the part schema dump cannot emit: the composite
    # foreign key and the list-ownership triggers. It is idempotent so
    # schema:load can run it after the tables exist. It does not rewrite
    # statuses or projections.
    FEED_ROUTE_SQL = <<~SQL
      ALTER TABLE external_feed_routes
        DROP CONSTRAINT IF EXISTS fk_external_feed_routes_subscription_owner;
      ALTER TABLE external_feed_routes
        ADD CONSTRAINT fk_external_feed_routes_subscription_owner
        FOREIGN KEY (external_subscription_id, user_id)
        REFERENCES external_subscriptions (id, user_id)
        ON DELETE CASCADE;

      CREATE OR REPLACE FUNCTION external_feed_routes_enforce_list_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        owner_account_id bigint;
        list_account_id bigint;
      BEGIN
        IF NEW.destination = 'list' THEN
          -- User, then list. Share locks conflict with an uncommitted
          -- account_id update and do not conflict with each other.
          -- https://www.postgresql.org/docs/16/explicit-locking.html
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
      DROP TRIGGER IF EXISTS external_feed_routes_enforce_list_owner ON external_feed_routes;
      CREATE TRIGGER external_feed_routes_enforce_list_owner
      BEFORE INSERT OR UPDATE OF user_id, list_id, destination
      ON external_feed_routes
      FOR EACH ROW
      EXECUTE FUNCTION external_feed_routes_enforce_list_owner();

      CREATE OR REPLACE FUNCTION lists_external_feed_routes_account_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.account_id IS DISTINCT FROM OLD.account_id
           AND EXISTS (SELECT 1 FROM external_feed_routes WHERE list_id = OLD.id) THEN
          RAISE EXCEPTION 'lists.account_id cannot change while an external feed route points at it'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS lists_external_feed_routes_account_guard ON lists;
      CREATE TRIGGER lists_external_feed_routes_account_guard
      BEFORE UPDATE OF account_id ON lists
      FOR EACH ROW
      EXECUTE FUNCTION lists_external_feed_routes_account_guard();
    SQL

    # Account id on the user cannot move while a projection, feed route, or
    # link-reference mapping still names that user. Reference statuses are
    # ordinary account posts and are not deleted here.
    USER_ACCOUNT_GUARD_FUNCTION_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION users_external_projection_account_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.account_id IS DISTINCT FROM OLD.account_id
           AND (
             EXISTS (SELECT 1 FROM external_status_projections WHERE user_id = OLD.id)
             OR EXISTS (SELECT 1 FROM external_feed_routes WHERE user_id = OLD.id)
             OR EXISTS (SELECT 1 FROM external_projection_link_references WHERE user_id = OLD.id)
           ) THEN
          RAISE EXCEPTION 'users.account_id cannot change while an external projection, feed route, or link reference exists'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    # Owner, scope, and broken-mapping guards for E4-A. Idempotent. schema:load
    # runs this after the tables exist. It does not rewrite statuses.
    LINK_REFERENCE_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION external_projection_link_references_enforce_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        user_account_id bigint;
        status_account_id bigint;
        status_projection boolean;
        status_visibility integer;
        status_deleted timestamp;
        projection_user_id bigint;
        projection_account_id bigint;
        projection_marker_status_id bigint;
        expected_visibility integer;
      BEGIN
        IF NEW.visibility = 'public' THEN
          expected_visibility := 0;
        ELSIF NEW.visibility = 'unlisted' THEN
          expected_visibility := 1;
        ELSE
          RAISE EXCEPTION 'external link reference visibility is invalid'
            USING ERRCODE = 'check_violation';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF OLD.state = 'broken' AND NEW.state IS DISTINCT FROM 'broken' THEN
            RAISE EXCEPTION 'broken external link reference cannot be reused'
              USING ERRCODE = 'check_violation';
          END IF;

          IF OLD.state = 'superseded' AND NEW.state = 'active' THEN
            RAISE EXCEPTION 'superseded external link reference cannot be reused'
              USING ERRCODE = 'check_violation';
          END IF;

          IF NEW.user_id IS DISTINCT FROM OLD.user_id
             OR NEW.account_id IS DISTINCT FROM OLD.account_id
             OR NEW.visibility IS DISTINCT FROM OLD.visibility
             OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url
             OR NEW.policy_revision IS DISTINCT FROM OLD.policy_revision
             OR NEW.projection_status_id IS DISTINCT FROM OLD.projection_status_id
             OR NEW.resource_revision IS DISTINCT FROM OLD.resource_revision
             OR (
               NEW.reference_status_id IS DISTINCT FROM OLD.reference_status_id
               AND NEW.reference_status_id IS NOT NULL
             )
             OR (
               NEW.external_status_projection_id IS DISTINCT FROM OLD.external_status_projection_id
               AND NEW.external_status_projection_id IS NOT NULL
             ) THEN
            RAISE EXCEPTION 'external link reference identifiers are immutable'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        SELECT account_id INTO user_account_id FROM users WHERE id = NEW.user_id FOR SHARE;
        IF user_account_id IS NULL OR user_account_id IS DISTINCT FROM NEW.account_id THEN
          RAISE EXCEPTION 'external link reference account mismatch'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.reference_status_id IS NOT NULL THEN
          SELECT account_id, external_projection, visibility, deleted_at
            INTO status_account_id, status_projection, status_visibility, status_deleted
          FROM statuses
          WHERE id = NEW.reference_status_id
          FOR SHARE;

          IF status_account_id IS NULL
             OR status_account_id IS DISTINCT FROM NEW.account_id
             OR status_projection IS TRUE
             OR status_visibility IS DISTINCT FROM expected_visibility
             OR (status_deleted IS NOT NULL AND NEW.state IS DISTINCT FROM 'broken') THEN
            RAISE EXCEPTION 'external link reference status shape is invalid'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        IF NEW.external_status_projection_id IS NOT NULL THEN
          SELECT user_id, account_id, status_id
            INTO projection_user_id, projection_account_id, projection_marker_status_id
          FROM external_status_projections
          WHERE id = NEW.external_status_projection_id
          FOR SHARE;

          IF projection_user_id IS NULL
             OR projection_user_id IS DISTINCT FROM NEW.user_id
             OR projection_account_id IS DISTINCT FROM NEW.account_id THEN
            RAISE EXCEPTION 'external link reference projection owner mismatch'
              USING ERRCODE = 'check_violation';
          END IF;

          IF projection_marker_status_id IS DISTINCT FROM NEW.projection_status_id THEN
            RAISE EXCEPTION 'external link reference projection status mismatch'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS external_projection_link_references_enforce_owner ON external_projection_link_references;
      CREATE TRIGGER external_projection_link_references_enforce_owner
      BEFORE INSERT OR UPDATE ON external_projection_link_references
      FOR EACH ROW
      EXECUTE FUNCTION external_projection_link_references_enforce_owner();

      CREATE OR REPLACE FUNCTION external_projection_link_references_mark_broken()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        UPDATE external_projection_link_references
           SET state = 'broken',
               reference_status_id = NULL,
               updated_at = clock_timestamp()
         WHERE reference_status_id = OLD.id
           AND state IS DISTINCT FROM 'broken';
        RETURN OLD;
      END;
      $$;
      DROP TRIGGER IF EXISTS external_projection_link_references_mark_broken ON statuses;
      CREATE TRIGGER external_projection_link_references_mark_broken
      BEFORE DELETE ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION external_projection_link_references_mark_broken();
    SQL

    # Durable publish mark. Separate from the owner trigger so a database that
    # has not added published_at yet can still install the owner guard.
    # schema:load runs this after the column exists.
    LINK_REFERENCE_PUBLISH_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION external_projection_link_references_publish_mark()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.published_at IS NOT NULL AND NEW.published_at IS DISTINCT FROM OLD.published_at THEN
          RAISE EXCEPTION 'external link reference publish mark is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS external_projection_link_references_publish_mark ON external_projection_link_references;
      CREATE TRIGGER external_projection_link_references_publish_mark
      BEFORE UPDATE OF published_at ON external_projection_link_references
      FOR EACH ROW
      EXECUTE FUNCTION external_projection_link_references_publish_mark();
    SQL

    # Rollback floor for the E4-A tables. Locks are taken before the existence
    # check and held until the migration transaction ends, so an INSERT cannot
    # land between the check and DROP. Policies are locked before references,
    # matching EnsureReference. statuses is not locked here.
    #
    # SHARE ROW EXCLUSIVE blocks INSERT/UPDATE/DELETE and SELECT FOR UPDATE,
    # and still allows plain reads. An empty down that then drops the table
    # upgrades the lock; a concurrent writer can deadlock that upgrade, the
    # down aborts, and the rows stay.
    LINK_SHARING_ROLLBACK_FLOOR_SQL = <<~SQL
      DO $$
      BEGIN
        IF to_regclass('public.external_link_share_policies') IS NOT NULL THEN
          LOCK TABLE external_link_share_policies IN SHARE ROW EXCLUSIVE MODE;
        END IF;

        IF to_regclass('public.external_projection_link_references') IS NOT NULL THEN
          LOCK TABLE external_projection_link_references IN SHARE ROW EXCLUSIVE MODE;
        END IF;

        IF to_regclass('public.external_projection_link_references') IS NOT NULL
           AND EXISTS (SELECT 1 FROM external_projection_link_references) THEN
          RAISE EXCEPTION 'refusing to roll back external link sharing while a reference mapping exists'
            USING ERRCODE = 'check_violation';
        END IF;

        IF to_regclass('public.external_link_share_policies') IS NOT NULL
           AND EXISTS (SELECT 1 FROM external_link_share_policies) THEN
          RAISE EXCEPTION 'refusing to roll back external link sharing while a share policy exists'
            USING ERRCODE = 'check_violation';
        END IF;
      END $$;
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

      #{USER_ACCOUNT_GUARD_FUNCTION_SQL}
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

      #{FEED_ROUTE_SQL}

      #{LINK_REFERENCE_SQL}

      #{LINK_REFERENCE_PUBLISH_SQL}

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
