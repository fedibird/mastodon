# frozen_string_literal: true

# Whether the subscription_removed streaming event for an accepted unsubscribe
# was handed to Sidekiq. Null means it was not: the deletion job sends it again
# from route_targets. A Redis failure while accepting the unsubscribe must not
# fail the HTTP request or skip the deletion job, and the event stays
# recoverable. One nullable column, no default, no rewrite.
class AddExternalSubscriptionDeletionControlEnqueuedAt < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_column :external_subscription_deletions, :control_enqueued_at, :datetime
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      remove_column :external_subscription_deletions, :control_enqueued_at
    end
  end
end
