# frozen_string_literal: true

# Claim token and distribution timestamp for the one-time founding follow.
# Both are nullable. Existing rows, if any, stay pending without a claim.
# This does not insert follows and does not lock the follows table.
class AddGroupInitialFollowClaim < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      add_column :group_initial_follows, :claim_token, :string, limit: 36
      add_column :group_initial_follows, :distribution_enqueued_at, :datetime
      add_column :group_initial_follows, :home_feed_partial_required, :boolean, null: false, default: false
      add_column :group_initial_follows, :shadow_observation_required, :boolean, null: false, default: false
      add_column :group_initial_follows, :shadow_target_locked, :boolean, null: false, default: false
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      remove_column :group_initial_follows, :shadow_target_locked
      remove_column :group_initial_follows, :shadow_observation_required
      remove_column :group_initial_follows, :home_feed_partial_required
      remove_column :group_initial_follows, :distribution_enqueued_at
      remove_column :group_initial_follows, :claim_token
    end
  end
end
