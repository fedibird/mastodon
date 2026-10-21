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
             OR NEW.quote_id IS DISTINCT FROM OLD.quote_id THEN
            RAISE EXCEPTION 'external projection status fields are immutable'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS statuses_external_projection_field_guard ON statuses;
      CREATE TRIGGER statuses_external_projection_field_guard
      BEFORE UPDATE OF account_id, visibility, searchability, uri, external_projection, deleted_at, reblog_of_id, in_reply_to_id, quote_id
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
      BEFORE INSERT ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_visibility_shape_guard();
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
             OR NEW.quote_id IS DISTINCT FROM OLD.quote_id THEN
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

    # Attaching a new BEFORE INSERT trigger takes ACCESS EXCLUSIVE on statuses.
    # It does not rewrite the table. The migration sets lock_timeout so a busy
    # table fails the migration instead of waiting. Existing triggers stay in
    # place; CREATE OR REPLACE FUNCTION updates their bodies.
    SHAPE_TRIGGER_ATTACH_SQL = <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_trigger
          WHERE tgname = 'statuses_external_visibility_shape_guard'
            AND NOT tgisinternal
        ) THEN
          CREATE TRIGGER statuses_external_visibility_shape_guard
          BEFORE INSERT ON statuses
          FOR EACH ROW
          EXECUTE FUNCTION statuses_external_visibility_shape_guard();
        END IF;
      END $$;
    SQL
  end
end
