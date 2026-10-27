# frozen_string_literal: true

# Proof and recheck rows for external media GC (issue #588, P3-B review).
#
# Attachment intents gain captured_projection_id. A proof row is inserted
# only while external_projection_attachments still points at the file. The
# trigger copies that link's attachment, projection, owner, and status, and
# then refuses to retarget them. The proof has no foreign key, so purging
# the projection does not delete the evidence.
#
# Asset rechecks have no uniqueness constraint. Each transaction that drops
# a projection link inserts one. A concurrent purge can lose the INSERT of
# a pending asset intent to the partial unique index; the recheck still
# commits with that transaction and is what schedules the next look.
#
# The intents table is empty on this branch. The migration refuses to
# continue if an attachment plan is already stored, because those rows have
# no projection id to backfill.
class BindExternalMediaGcProofs < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"

      execute <<~SQL.squish
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM external_media_gc_intents
            WHERE target_type = 'media_attachment'
          ) THEN
            RAISE EXCEPTION 'external_media_gc_intents already has attachment plans';
          END IF;
        END $$;
      SQL

      add_column :external_media_gc_intents, :captured_projection_id, :bigint

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        DROP CONSTRAINT external_media_gc_intents_reason_check
      SQL

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        ADD CONSTRAINT external_media_gc_intents_reason_check
        CHECK (
          (
            target_type = 'external_media_asset'
            AND reason IN ('projection_purge', 'asset_unreferenced', 'generation_replaced')
          ) OR (
            target_type = 'media_attachment'
            AND reason IN ('projection_purge', 'attachment_replaced')
            AND owner_account_id IS NOT NULL
            AND captured_status_id IS NOT NULL
            AND source_attachment_id IS NOT NULL
            AND captured_projection_id IS NOT NULL
          )
        )
      SQL

      create_table :external_media_gc_proofs do |t|
        t.bigint :source_attachment_id, null: false
        t.bigint :media_attachment_id, null: false
        t.bigint :external_status_projection_id, null: false
        t.bigint :account_id, null: false
        t.bigint :status_id, null: false
        t.timestamps
      end
      add_index :external_media_gc_proofs, :source_attachment_id, unique: true, name: 'index_ext_media_gc_proofs_on_link'

      create_table :external_media_gc_asset_rechecks do |t|
        t.bigint :external_media_asset_id, null: false
        t.string :reason, null: false, limit: 32
        t.string :state, null: false, default: 'pending', limit: 16
        t.bigint :external_subscription_deletion_id
        t.datetime :available_at, null: false
        t.string :last_error_code, limit: 64
        t.datetime :resolved_at
        t.timestamps
      end

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_asset_rechecks
        ADD CONSTRAINT external_media_gc_asset_rechecks_state_check
        CHECK (state IN ('pending', 'done'))
      SQL

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_asset_rechecks
        ADD CONSTRAINT external_media_gc_asset_rechecks_reason_check
        CHECK (reason IN ('projection_purge', 'asset_unreferenced', 'generation_replaced'))
      SQL

      execute <<~SQL.squish
        CREATE INDEX index_ext_media_gc_rechecks_on_due
        ON external_media_gc_asset_rechecks (available_at, id)
        WHERE state = 'pending'
      SQL

      execute ExternalBridge::Schema::MEDIA_GC_PROOF_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute 'DROP TRIGGER IF EXISTS external_media_gc_proofs_bind ON external_media_gc_proofs'
      execute 'DROP FUNCTION IF EXISTS external_media_gc_proofs_bind()'
      drop_table :external_media_gc_asset_rechecks
      drop_table :external_media_gc_proofs

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        DROP CONSTRAINT external_media_gc_intents_reason_check
      SQL

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        ADD CONSTRAINT external_media_gc_intents_reason_check
        CHECK (
          (
            target_type = 'external_media_asset'
            AND reason IN ('projection_purge', 'asset_unreferenced', 'generation_replaced')
          ) OR (
            target_type = 'media_attachment'
            AND reason IN ('projection_purge', 'attachment_replaced')
            AND owner_account_id IS NOT NULL
            AND captured_status_id IS NOT NULL
            AND source_attachment_id IS NOT NULL
          )
        )
      SQL

      remove_column :external_media_gc_intents, :captured_projection_id
    end
  end
end
