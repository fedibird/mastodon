# frozen_string_literal: true

# The token names which job owns a presentation rewrite. A later claim can
# replace it only after presentation_lease_until has passed, so a delayed
# worker and the recovery job cannot both update the same statuses.
# Nullable, no default, catalog-only. No rewrite of statuses.
class AddPresentationLeaseTokenToExternalSubscriptions < ActiveRecord::Migration[6.1]
  def change
    add_column :external_subscriptions, :presentation_lease_token, :string
  end
end