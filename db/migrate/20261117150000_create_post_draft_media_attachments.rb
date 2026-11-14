# frozen_string_literal: true

class CreatePostDraftMediaAttachments < ActiveRecord::Migration[6.1]
  # New empty join table. media_attachments is not rewritten: a draft
  # reference is a row here, not a column on that table. One attachment
  # can belong to one draft. Deleting the draft removes the reference
  # and leaves the file. Deleting the file is refused while a reference
  # remains.
  def change
    create_table :post_draft_media_attachments do |t|
      t.references :post_draft, null: false, foreign_key: { on_delete: :cascade }, index: false, type: :bigint
      t.references :media_attachment, null: false, foreign_key: { on_delete: :restrict }, index: false, type: :bigint
      t.integer :position, null: false

      t.index :media_attachment_id, unique: true, name: 'index_post_draft_media_on_media_attachment_id'
      t.index [:post_draft_id, :position], unique: true, name: 'index_post_draft_media_on_draft_and_position'
      t.check_constraint 'position >= 0 AND position < 20', name: 'post_draft_media_attachments_position'
    end
  end
end
