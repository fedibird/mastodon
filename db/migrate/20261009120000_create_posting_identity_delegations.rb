# frozen_string_literal: true

class CreatePostingIdentityDelegations < ActiveRecord::Migration[6.1]
  def change
    create_table :posting_identity_link_requests do |t|
      t.references :requester_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.references :target_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.string :token_digest, null: false, limit: 64
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :canceled_at

      t.timestamps

      t.index :token_digest, unique: true, name: 'index_posting_identity_link_requests_on_token_digest'
    end

    create_table :posting_identity_delegations do |t|
      t.references :grantor_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.references :grantee_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.references :posting_account, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }, index: true
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :approved_at, null: false
      t.datetime :revoked_at
      t.datetime :superseded_at
      t.datetime :last_used_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.index [:grantee_user_id, :grantor_user_id],
              unique: true,
              where: 'revoked_at IS NULL AND superseded_at IS NULL',
              name: 'index_posting_identity_delegations_one_active_pair'
    end
  end
end
