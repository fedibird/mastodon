# frozen_string_literal: true

class CreatePostingIdentityMedia < ActiveRecord::Migration[6.1]
  def change
    create_table :posting_identity_media do |t|
      t.references :grantee_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, index: true
      t.references :delegation, null: false, foreign_key: { to_table: :posting_identity_delegations, on_delete: :cascade }, index: true
      t.references :posting_account, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }, index: true
      # media_attachment_id identifies the upload. It is not a foreign key,
      # so media cleanup can delete the file without deleting this row and
      # without keeping a copy of the description.
      t.bigint :media_attachment_id, null: false

      t.timestamps

      t.index :media_attachment_id, unique: true
    end
  end
end
