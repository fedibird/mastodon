# frozen_string_literal: true

# Public RSS/Atom cache plus owner-private status projections.
#
# statuses.external_projection is a nullable boolean with no default and no
# index. On PostgreSQL 11+ that is a catalog change: existing rows stay null
# and the table is not rewritten. Do not add an index on this column and do
# not add a unique index on statuses(id, account_id). The account match is
# the ordinary BEFORE row trigger below.
class CreateExternalBridgeRSS < ActiveRecord::Migration[6.1]
  def up
    safety_assured { add_column :statuses, :external_projection, :boolean }
    create_actor_table
    create_source_table
    create_resource_table
    create_subscription_table
    create_projection_table
    safety_assured { execute composite_foreign_keys_sql }
    safety_assured { execute trigger_sql }
  end

  def down
    safety_assured { execute drop_trigger_sql }
    drop_table :external_status_projections
    drop_table :external_subscriptions
    drop_table :external_resources
    drop_table :external_sources
    drop_table :external_actors
    safety_assured { remove_column :statuses, :external_projection }
  end

  private

  def create_actor_table
    create_table :external_actors do |t|
      t.string :protocol, null: false
      t.text :native_id, null: false
      t.string :handle
      t.string :display_name
      t.text :profile_url
      t.text :avatar_remote_url
      t.timestamps
    end
    add_index :external_actors, [:protocol, :native_id], unique: true, name: 'index_external_actors_on_protocol_and_native_id'
    add_check_constraint :external_actors, "protocol IN ('rss', 'atom')", name: 'external_actors_protocol_check'
  end

  def create_source_table
    create_table :external_sources do |t|
      t.string :protocol, null: false
      t.text :canonical_key, null: false
      t.text :etag
      t.text :last_modified
      t.datetime :fetched_at
      t.datetime :checked_at
      t.text :title
      t.text :site_url
      t.timestamps
    end
    add_index :external_sources, [:protocol, :canonical_key], unique: true, name: 'index_external_sources_on_protocol_and_canonical_key'
    add_index :external_sources, :canonical_key, name: 'index_external_sources_on_canonical_key'
    add_check_constraint :external_sources, "protocol IN ('rss', 'atom')", name: 'external_sources_protocol_check'
  end

  def create_resource_table
    create_table :external_resources do |t|
      t.references :external_source, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :external_actor, foreign_key: { on_delete: :nullify }
      t.string :protocol, null: false
      t.text :canonical_key, null: false
      t.text :revision
      t.text :canonical_url
      t.text :title
      t.text :body
      t.text :byline
      t.string :body_digest
      t.datetime :published_at
      t.datetime :source_deleted_at
      t.boolean :truncated, null: false, default: false
      t.datetime :fetched_at
      t.timestamps
    end
    add_index :external_resources, [:protocol, :canonical_key], unique: true, name: 'index_external_resources_on_protocol_and_canonical_key'
    add_index :external_resources, [:id, :external_source_id], unique: true, name: 'index_external_resources_on_id_and_source'
    add_index :external_resources, [:external_source_id, :published_at], name: 'index_external_resources_on_source_and_published_at'
    add_check_constraint :external_resources, "protocol IN ('rss', 'atom')", name: 'external_resources_protocol_check'
  end

  def create_subscription_table
    create_table :external_subscriptions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :external_source, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :state, null: false, default: 'active'
      t.string :last_error_code
      t.datetime :last_error_at
      t.datetime :checked_at
      t.timestamps
    end
    add_index :external_subscriptions, [:user_id, :external_source_id], unique: true, name: 'index_external_subscriptions_on_user_and_source'
    add_index :external_subscriptions, [:id, :user_id, :external_source_id], unique: true, name: 'index_external_subscriptions_on_id_user_and_source'
    add_index :external_subscriptions, :external_source_id, name: 'index_external_subscriptions_on_external_source_id'
    add_check_constraint :external_subscriptions, "state IN ('active', 'paused', 'error')", name: 'external_subscriptions_state_check'
  end

  def create_projection_table
    create_table :external_status_projections do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :account, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :external_source_id, null: false
      t.bigint :external_subscription_id, null: false
      t.bigint :external_resource_id, null: false
      t.references :status, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.text :last_seen_revision
      t.boolean :source_deleted, null: false, default: false
      t.timestamps
    end
    add_index :external_status_projections, [:user_id, :external_resource_id], unique: true, name: 'index_external_status_projections_on_user_and_resource'
    add_index :external_status_projections, :external_subscription_id, name: 'index_external_status_projections_on_subscription'
  end

  def composite_foreign_keys_sql
    <<~SQL
      ALTER TABLE external_status_projections
        ADD CONSTRAINT fk_external_projections_subscription_owner
        FOREIGN KEY (external_subscription_id, user_id, external_source_id)
        REFERENCES external_subscriptions (id, user_id, external_source_id);
      ALTER TABLE external_status_projections
        ADD CONSTRAINT fk_external_projections_resource_source
        FOREIGN KEY (external_resource_id, external_source_id)
        REFERENCES external_resources (id, external_source_id);
    SQL
  end

  def trigger_sql
    [owner_account_trigger_sql, guard_delete_trigger_sql, status_field_trigger_sql, user_account_trigger_sql].join("\n")
  end

  def owner_account_trigger_sql
    <<~SQL
      CREATE FUNCTION external_status_projections_enforce_owner_account()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        user_account_id bigint;
        status_account_id bigint;
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
        SELECT account_id INTO status_account_id FROM statuses WHERE id = NEW.status_id FOR SHARE;

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

      CREATE TRIGGER external_status_projections_user_account
      BEFORE INSERT OR UPDATE OF user_id, account_id, status_id
      ON external_status_projections
      FOR EACH ROW
      EXECUTE FUNCTION external_status_projections_enforce_owner_account();
    SQL
  end

  def guard_delete_trigger_sql
    <<~SQL
      CREATE FUNCTION external_status_projections_guard_delete()
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

      CREATE TRIGGER external_status_projections_guard_delete
      BEFORE DELETE
      ON external_status_projections
      FOR EACH ROW
      EXECUTE FUNCTION external_status_projections_guard_delete();
    SQL
  end

  def status_field_trigger_sql
    <<~SQL
      CREATE FUNCTION statuses_external_projection_field_guard()
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

      CREATE TRIGGER statuses_external_projection_field_guard
      BEFORE UPDATE OF account_id, visibility, searchability, uri, external_projection, deleted_at, reblog_of_id, in_reply_to_id, quote_id
      ON statuses
      FOR EACH ROW
      EXECUTE FUNCTION statuses_external_projection_field_guard();
    SQL
  end

  def user_account_trigger_sql
    <<~SQL
      CREATE FUNCTION users_external_projection_account_guard()
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

      CREATE TRIGGER users_external_projection_account_guard
      BEFORE UPDATE OF account_id
      ON users
      FOR EACH ROW
      EXECUTE FUNCTION users_external_projection_account_guard();
    SQL
  end

  def drop_trigger_sql
    <<~SQL
      DROP TRIGGER IF EXISTS users_external_projection_account_guard ON users;
      DROP FUNCTION IF EXISTS users_external_projection_account_guard();
      DROP TRIGGER IF EXISTS statuses_external_projection_field_guard ON statuses;
      DROP FUNCTION IF EXISTS statuses_external_projection_field_guard();
      DROP TRIGGER IF EXISTS external_status_projections_guard_delete ON external_status_projections;
      DROP FUNCTION IF EXISTS external_status_projections_guard_delete();
      DROP TRIGGER IF EXISTS external_status_projections_user_account ON external_status_projections;
      DROP FUNCTION IF EXISTS external_status_projections_enforce_owner_account();
    SQL
  end
end
