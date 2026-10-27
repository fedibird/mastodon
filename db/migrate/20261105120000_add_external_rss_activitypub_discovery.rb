# frozen_string_literal: true

# Public, shared ActivityPub discovery metadata. No status, account, or
# projection row is changed. Unknown is deliberately distinct from unavailable.
class AddExternalRSSActivityPubDiscovery < ActiveRecord::Migration[6.1]
  def change
    add_column :external_sources, :activitypub_state, :string, null: false, default: 'unknown'
    add_column :external_sources, :activitypub_hint, :boolean, null: false, default: false
    add_column :external_sources, :activitypub_instance_state, :string, null: false, default: 'unknown'
    add_column :external_sources, :activitypub_software, :string
    add_column :external_sources, :activitypub_instance_checked_at, :datetime
    add_column :external_sources, :activitypub_instance_next_check_at, :datetime

    add_column :external_resources, :activitypub_state, :string, null: false, default: 'unknown'
    add_column :external_resources, :activitypub_candidate_url, :text
    add_column :external_resources, :activitypub_object_id, :text
    add_column :external_resources, :activitypub_object_type, :string
    add_column :external_resources, :activitypub_checked_at, :datetime
    add_column :external_resources, :activitypub_next_check_at, :datetime
  end
end
