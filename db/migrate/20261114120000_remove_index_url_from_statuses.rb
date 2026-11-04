# frozen_string_literal: true

# P2 of #693. Status lookups now resolve by ActivityPub URI; the public URL
# remains stored for display and checked only after selecting by indexed URI.
#
# Keep the rollback explicit: recreating this index on a large statuses table
# may require substantial time and free disk space.
class RemoveIndexUrlFromStatuses < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  INDEX_NAME = :index_statuses_on_url

  def up
    safety_assured do
      remove_index :statuses, name: INDEX_NAME, algorithm: :concurrently
    end
  end

  def down
    safety_assured do
      add_index :statuses, :url, name: INDEX_NAME, algorithm: :concurrently
    end
  end
end
