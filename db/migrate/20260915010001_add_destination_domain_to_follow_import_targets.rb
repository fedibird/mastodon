# frozen_string_literal: true

class AddDestinationDomainToFollowImportTargets < ActiveRecord::Migration[6.1]
  def change
    # Routing metadata for a future per-domain scheduler. Nullable so unresolved
    # and pre-existing rows stay valid. Not a moderation signal.
    add_column :follow_import_targets, :destination_domain, :string

    safety_assured do
      add_index :follow_import_targets, :destination_domain,
                where: 'destination_domain IS NOT NULL',
                name: :index_follow_import_targets_on_destination_domain
    end
  end
end
