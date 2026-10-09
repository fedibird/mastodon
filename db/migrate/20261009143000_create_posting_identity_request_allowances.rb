# frozen_string_literal: true

class CreatePostingIdentityRequestAllowances < ActiveRecord::Migration[6.1]
  def change
    create_table :posting_identity_request_allowances do |t|
      t.references :grantor_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: false
      t.references :requester_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.string :allowed_scopes, array: true, null: false, default: []
      t.datetime :allowed_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.integer :generation, null: false, default: 1
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.index [:grantor_user_id, :requester_user_id],
              unique: true,
              name: 'index_posting_identity_request_allowances_on_pair'
    end

    add_column :posting_identity_link_requests, :request_allowance_id, :bigint
    add_column :posting_identity_link_requests, :allowance_generation, :integer
    add_foreign_key :posting_identity_link_requests, :posting_identity_request_allowances,
                     column: :request_allowance_id, on_delete: :nullify, validate: false
  end
end

