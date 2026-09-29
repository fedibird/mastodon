# frozen_string_literal: true

class CreateUserExternalCredentials < ActiveRecord::Migration[6.1]
  def change
    create_table :user_external_credentials do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :provider, null: false, limit: 64
      t.string :purpose, null: false, limit: 64
      t.string :credential_type, null: false, limit: 64
      t.string :binding_id, null: false, limit: 36
      t.text :encrypted_payload, null: false
      t.string :encryption_key_id, null: false, limit: 32
      t.string :display_name, limit: 100
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at

      t.timestamps

      t.index :binding_id, unique: true
      t.index :encryption_key_id
      t.index [:user_id, :provider, :purpose], name: 'index_user_external_credentials_on_owner_use'
    end
  end
end
