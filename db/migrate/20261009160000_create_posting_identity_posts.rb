# frozen_string_literal: true

class CreatePostingIdentityPosts < ActiveRecord::Migration[6.1]
  def change
    create_table :posting_identity_posts do |t|
      t.references :grantee_user, null: false, foreign_key: { to_table: :users }, index: true
      t.references :delegation, null: false, foreign_key: { to_table: :posting_identity_delegations }, index: true
      t.references :posting_account, null: false, foreign_key: { to_table: :accounts }, index: true
      t.references :status, null: false, foreign_key: true, index: { unique: true }
      t.datetime :posted_at, null: false

      t.timestamps
    end
  end
end
