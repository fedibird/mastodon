# frozen_string_literal: true

class CreateReboostAnnounceState < ActiveRecord::Migration[6.1]
  def change
    create_table :reboost_announce_states do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :reblog_of, foreign_key: { to_table: :statuses, on_delete: :cascade }
      t.string :uri, null: false
      t.datetime :published_at
      t.string :state, null: false
      t.timestamps
    end
    add_index :reboost_announce_states, [:account_id, :uri], unique: true, name: 'index_reboost_announce_states_on_account_and_uri'
    add_index :reboost_announce_states, [:account_id, :reblog_of_id], unique: true, where: "state = 'current' AND reblog_of_id IS NOT NULL", name: 'index_reboost_announce_states_one_current'

    create_table :remote_reboost_holds do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :reblog_of, null: false, foreign_key: { to_table: :statuses, on_delete: :cascade }
      t.string :activity_uri, null: false
      t.datetime :published_at
      t.datetime :available_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :remote_reboost_holds, [:account_id, :reblog_of_id], unique: true, name: 'index_remote_reboost_holds_on_account_and_status'
  end
end
