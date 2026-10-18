# frozen_string_literal: true

class CreateTimelineReadingBookmarks < ActiveRecord::Migration[6.1]
  # New empty table. No rewrite of users, statuses, markers, bookmarks, or
  # preference rows. Checks are validated immediately because nothing is in
  # the table yet.
  def change
    create_table :timeline_reading_bookmarks do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false, type: :bigint
      t.string :name, null: false, limit: 100
      t.string :source, null: false, limit: 16
      t.jsonb :context, null: false, default: {}
      t.integer :anchor_version, null: false, default: 1
      t.string :anchor_status_id, null: false, limit: 19
      t.string :display_row_id, limit: 128
      t.integer :offset_px, null: false
      t.string :alignment, null: false, limit: 8
      t.datetime :captured_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.index [:user_id, :name], unique: true, name: 'index_timeline_reading_bookmarks_on_user_and_name'
      t.index [:user_id, :updated_at], name: 'index_timeline_reading_bookmarks_on_user_and_updated_at'
      t.check_constraint <<~SQL.squish, name: 'timeline_reading_bookmarks_shape'
        char_length(name) BETWEEN 1 AND 100
        AND name !~ '[[:cntrl:]]'
        AND btrim(name) = name
        AND source IN ('home', 'limited', 'list', 'hashtag', 'public', 'domain', 'group', 'personal')
        AND alignment IN ('top', 'center')
        AND anchor_version = 1
        AND offset_px BETWEEN -1000000 AND 1000000
        AND anchor_status_id ~ '^[1-9][0-9]{0,18}$'
        AND (
          display_row_id IS NULL
          OR (char_length(display_row_id) BETWEEN 1 AND 128 AND display_row_id !~ '[[:cntrl:]]')
        )
        AND octet_length(context::text) <= 2048
      SQL
    end
  end
end
