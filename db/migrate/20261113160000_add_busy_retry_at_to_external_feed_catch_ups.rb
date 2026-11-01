# frozen_string_literal: true

# When a catch-up is waiting for the shared drain to commit a position, one
# delayed retry is recorded here so a second wait does not stack another job.
# PostgreSQL 11 adds a nullable column without a table rewrite.
class AddBusyRetryAtToExternalFeedCatchUps < ActiveRecord::Migration[6.1]
  def change
    add_column :external_feed_catch_ups, :busy_retry_at, :datetime
  end
end
