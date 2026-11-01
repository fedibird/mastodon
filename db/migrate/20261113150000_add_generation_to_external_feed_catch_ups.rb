# frozen_string_literal: true

# High-water generation for one subscriber's catch-up cursor.
#
# The value is the latest snapshot generation this cursor has entered.
# A purged or deleted body must not send the cursor back to an older
# generation. Existing rows start at 0, which is before every real
# generation, so the next batch still finds the first snapshot.
# PostgreSQL 11 stores the constant default in the catalog.
class AddGenerationToExternalFeedCatchUps < ActiveRecord::Migration[6.1]
  def change
    add_column :external_feed_catch_ups, :generation, :integer, null: false, default: 0
  end
end
