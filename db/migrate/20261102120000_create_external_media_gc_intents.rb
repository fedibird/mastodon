# frozen_string_literal: true

# Durable file-release plans for external RSS/Atom media (issue #588, P3-B).
#
# Projection purge deletes statuses with SQL. That cascades the projection
# and its external_projection_attachments rows and nullifies
# media_attachments.status_id. The bytes are a different step. Writing the
# plan in the same transaction as the DELETE means a process that dies
# before Paperclip destroy still has a row to retry. Recovery reads this
# table. It does not receive a status id list, and it does not scan
# media_attachments where status_id is null: those rows include ordinary
# compose uploads.
#
# No existing table is rewritten and nothing is backfilled. The table starts
# empty. Dropping it only forgets plans that have not run; it does not
# delete media rows or files.
class CreateExternalMediaGcIntents < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"

      create_table :external_media_gc_intents do |t|
        t.string :target_type, null: false, limit: 32
        t.bigint :target_id, null: false
        t.string :reason, null: false, limit: 32
        t.string :state, null: false, default: 'pending', limit: 16
        t.bigint :owner_account_id
        t.bigint :captured_status_id
        t.bigint :source_attachment_id
        t.bigint :external_subscription_deletion_id
        t.datetime :available_at, null: false
        t.integer :attempt_count, null: false, default: 0
        t.string :last_error_code, limit: 64
        t.string :lease_token, limit: 32
        t.datetime :leased_until
        t.datetime :resolved_at
        t.timestamps
      end

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        ADD CONSTRAINT external_media_gc_intents_target_check
        CHECK (target_type IN ('media_attachment', 'external_media_asset'))
      SQL

      execute <<~SQL.squish
        ALTER TABLE external_media_gc_intents
        ADD CONSTRAINT external_media_gc_intents_state_check
        CHECK (state IN ('pending', 'released', 'retained', 'failed'))
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

      # Partial unique index. ON CONFLICT in MediaGc::Plan names this predicate.
      # schema:dump may rewrite it; keep the predicate as `state = 'pending'`.
      execute <<~SQL.squish
        CREATE UNIQUE INDEX index_ext_media_gc_open_target
        ON external_media_gc_intents (target_type, target_id)
        WHERE state = 'pending'
      SQL

      execute <<~SQL.squish
        CREATE INDEX index_ext_media_gc_intents_on_due
        ON external_media_gc_intents (available_at, id)
        WHERE state = 'pending'
      SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      drop_table :external_media_gc_intents
    end
  end
end
