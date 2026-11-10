# frozen_string_literal: true

class AddEmojiIdentitiesToStatusEdits < ActiveRecord::Migration[6.1]
  def change
    # Nullable on purpose. Rows saved before this column have no proof of
    # which local custom-emoji id the shortcode named, so they stay null
    # and the history serializer does not borrow the current row.
    add_column :status_edits, :emoji_identities, :jsonb
  end
end
