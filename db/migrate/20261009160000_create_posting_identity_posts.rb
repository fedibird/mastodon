# frozen_string_literal: true

class CreatePostingIdentityPosts < ActiveRecord::Migration[6.1]
  def change
    create_table :posting_identity_posts do |t|
      t.references :grantee_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.references :delegation, null: false, foreign_key: { to_table: :posting_identity_delegations, on_delete: :cascade }, index: true
      t.references :posting_account, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }, index: true
      # status_id is an immutable identifier. It is not a foreign key, so
      # RemoveStatusService can delete the status without removing this row.
      t.bigint :status_id, null: false
      t.datetime :posted_at, null: false

      t.timestamps

      t.index :status_id, unique: true
    end
  end
end
