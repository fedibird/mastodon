# frozen_string_literal: true

class CreateUserPostingContexts < ActiveRecord::Migration[6.1]
  def change
    create_table :user_posting_contexts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false, limit: 80
      t.string :icon, limit: 64
      t.text :purpose
      t.string :target_kind, null: false, default: 'none', limit: 16
      t.references :target_account, foreign_key: { to_table: :accounts, on_delete: :nullify }, index: true
      t.string :target_hashtag, limit: 100
      t.jsonb :defaults, null: false, default: {}
      t.jsonb :managed, null: false, default: {}
      t.integer :position, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.integer :schema_version, null: false, default: 1
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.index [:user_id, :position], name: 'index_user_posting_contexts_on_user_id_and_position'
    end
  end
end
