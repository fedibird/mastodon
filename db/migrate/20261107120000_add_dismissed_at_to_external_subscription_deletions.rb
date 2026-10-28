# frozen_string_literal: true

# When the owner closes a completed RSS unsubscribe card. Null means the card
# has not been closed. This hides the card only: the progress row, its effects,
# and the 30-day retention are unchanged. No default and no backfill.
class AddDismissedAtToExternalSubscriptionDeletions < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_column :external_subscription_deletions, :dismissed_at, :datetime
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      remove_column :external_subscription_deletions, :dismissed_at
    end
  end
end
