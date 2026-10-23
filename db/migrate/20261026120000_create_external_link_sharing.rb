# frozen_string_literal: true

# E4-A share policy and projection-to-reference mapping. No statuses column,
# no statuses rewrite, and no backfill of existing projections.
class CreateExternalLinkSharing < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      create_share_policies
      create_link_references
      execute ExternalBridge::Schema::USER_ACCOUNT_GUARD_FUNCTION_SQL
      execute ExternalBridge::Schema::LINK_REFERENCE_SQL
    end
  end

  def create_share_policies
    create_table :external_link_share_policies do |t|
      t.bigint :user_id, null: false
      t.boolean :enabled, null: false, default: false
      t.string :visibility, null: false, default: 'unlisted'
      t.integer :revision, null: false, default: 0
      t.datetime :consented_at
      t.timestamps
    end
    add_index :external_link_share_policies, :user_id, unique: true, name: 'index_link_share_policies_on_user_id'
    add_foreign_key :external_link_share_policies, :users, column: :user_id, on_delete: :cascade, name: 'fk_link_share_policies_user'
    add_check_constraint :external_link_share_policies,
                         "visibility IN ('public', 'unlisted')",
                         name: 'link_share_policies_visibility_check'
    add_check_constraint :external_link_share_policies,
                         'revision >= 0',
                         name: 'link_share_policies_revision_check'
    add_check_constraint :external_link_share_policies,
                         'enabled = false OR consented_at IS NOT NULL',
                         name: 'link_share_policies_consent_check'
  end

  def create_link_references
    create_table :external_projection_link_references do |t|
      t.bigint :user_id, null: false
      t.bigint :account_id, null: false
      t.bigint :external_status_projection_id
      t.bigint :projection_status_id, null: false
      t.bigint :reference_status_id
      t.string :visibility, null: false
      t.text :canonical_url, null: false
      t.text :resource_revision
      t.integer :policy_revision, null: false
      t.string :state, null: false, default: 'active'
      t.datetime :superseded_at
      t.timestamps
    end
    add_index :external_projection_link_references,
              [:user_id, :external_status_projection_id, :visibility, :canonical_url],
              unique: true,
              where: "state = 'active' AND external_status_projection_id IS NOT NULL",
              name: 'index_link_refs_on_active_identity'
    add_index :external_projection_link_references,
              :reference_status_id,
              unique: true,
              where: 'reference_status_id IS NOT NULL',
              name: 'index_link_refs_on_reference_status'
    add_index :external_projection_link_references, :user_id, name: 'index_link_refs_on_user_id'
    add_foreign_key :external_projection_link_references, :users, column: :user_id, on_delete: :cascade, name: 'fk_link_refs_user'
    add_foreign_key :external_projection_link_references, :accounts, column: :account_id, on_delete: :cascade, name: 'fk_link_refs_account'
    add_foreign_key :external_projection_link_references, :external_status_projections, column: :external_status_projection_id, on_delete: :nullify, name: 'fk_link_refs_projection'
    add_foreign_key :external_projection_link_references, :statuses, column: :reference_status_id, on_delete: :nullify, name: 'fk_link_refs_status'
    add_check_constraint :external_projection_link_references,
                         "visibility IN ('public', 'unlisted')",
                         name: 'link_refs_visibility_check'
    add_check_constraint :external_projection_link_references,
                         "state IN ('active', 'superseded', 'broken')",
                         name: 'link_refs_state_check'
    add_check_constraint :external_projection_link_references,
                         "state <> 'active' OR reference_status_id IS NOT NULL",
                         name: 'link_refs_active_requires_status'
    add_check_constraint :external_projection_link_references,
                         "state <> 'superseded' OR superseded_at IS NOT NULL",
                         name: 'link_refs_superseded_requires_time'
    add_check_constraint :external_projection_link_references,
                         "canonical_url ~ '^https?://'",
                         name: 'link_refs_canonical_url_check'
  end

  def down
    safety_assured do
      # One transaction so the table locks in the floor are still held when
      # DROP runs. A caller that already opened a transaction joins it.
      ActiveRecord::Base.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        execute ExternalBridge::Schema::LINK_SHARING_ROLLBACK_FLOOR_SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS external_projection_link_references_publish_mark ON external_projection_link_references;
          DROP TRIGGER IF EXISTS external_projection_link_references_mark_broken ON statuses;
          DROP TRIGGER IF EXISTS external_projection_link_references_enforce_owner ON external_projection_link_references;
        SQL
        execute <<~SQL
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
        drop_table :external_projection_link_references, if_exists: true
        execute <<~SQL
          DROP FUNCTION IF EXISTS external_projection_link_references_publish_mark();
          DROP FUNCTION IF EXISTS external_projection_link_references_mark_broken();
          DROP FUNCTION IF EXISTS external_projection_link_references_enforce_owner();
        SQL
        drop_table :external_link_share_policies, if_exists: true
      end
    end
  end
end
