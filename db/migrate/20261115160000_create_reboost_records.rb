# frozen_string_literal: true

class CreateReboostRecords < ActiveRecord::Migration[6.1]
  def change
    create_table :reboost_cooldowns do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :status, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :boosted_at, null: false
      t.timestamps
    end
    add_index :reboost_cooldowns, [:account_id, :status_id], unique: true, name: 'index_reboost_cooldowns_on_account_and_status'

    create_table :reboost_operations do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :reblog_of, null: false, foreign_key: { to_table: :statuses, on_delete: :cascade }
      t.bigint :old_status_id
      t.bigint :new_status_id
      t.string :state, null: false
      t.string :visibility
      t.bigint :circle_id
      t.string :idempotency_key
      t.boolean :reboost, null: false, default: false
      t.datetime :available_at
      t.datetime :removal_started_at
      t.datetime :removal_finished_at
      t.datetime :completed_at
      t.string :error_code
      t.text :undo_payload
      t.jsonb :undo_inboxes, null: false, default: []
      t.jsonb :options, null: false, default: {}
      t.timestamps
    end
    add_index :reboost_operations, [:account_id, :reblog_of_id, :state], name: 'index_reboost_operations_on_account_status_and_state'
    add_index :reboost_operations, [:account_id, :idempotency_key], unique: true, where: 'idempotency_key IS NOT NULL', name: 'index_reboost_operations_on_idempotency'
  end
end
