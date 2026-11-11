# frozen_string_literal: true

class AddEmojiIdentitiesToStatuses < ActiveRecord::Migration[6.1]
  def change
    # Nullable on purpose. Statuses created before this column have no
    # record of which local custom-emoji id the original shortcode named.
    # The first edit snapshot leaves those local rows unproven.
    add_column :statuses, :emoji_identities, :jsonb
  end
end
