# frozen_string_literal: true

class AddStatusEditing < ActiveRecord::Migration[6.1]
  def change
    add_column :statuses, :edited_at, :datetime

    create_table :status_edits do |t|
      t.belongs_to :status, null: false, foreign_key: { on_delete: :cascade }
      t.belongs_to :account, null: true, foreign_key: { on_delete: :nullify }
      t.text :text, null: false, default: ''
      t.text :spoiler_text, null: false, default: ''
      t.bigint :ordered_media_attachment_ids, array: true
      t.text :media_descriptions, array: true
      t.string :poll_options, array: true
      t.boolean :sensitive

      t.timestamps
    end
  end
end
