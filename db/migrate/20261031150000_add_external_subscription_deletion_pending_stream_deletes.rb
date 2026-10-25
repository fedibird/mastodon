# frozen_string_literal: true

# Outbox for stream deletes of an asynchronous RSS unsubscribe.
#
# The physical DELETE removes the projection marker, which is the only other
# place the home/list destinations were stored. The captures are written in
# the same transaction as that DELETE. A Redis outage or a killed worker
# after the commit can push them later. One jsonb column on a small table
# (one row per unsubscribe), constant default, no rewrite of statuses.
class AddExternalSubscriptionDeletionPendingStreamDeletes < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_column :external_subscription_deletions, :pending_stream_deletes, :jsonb, null: false, default: []
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      remove_column :external_subscription_deletions, :pending_stream_deletes
    end
  end
end
