# frozen_string_literal: true

# Public, shared ActivityPub discovery metadata. No status, account, or
# projection row is changed. Unknown is deliberately distinct from unavailable.
#
# Columns use constant defaults so PostgreSQL 11+ updates only the catalog.
# Nothing backfills old rows. Partial indexes cover the probe scheduler:
# due explicit/ordinary candidates, the stable ordinary sample, and
# "does this source have any verified item?". Those reads stay index ranges
# when a source has hundreds of thousands of resources.
class AddExternalRSSActivityPubDiscovery < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  DUE_INDEX = 'index_external_resources_on_ap_probe_due'
  SAMPLE_INDEX = 'index_external_resources_on_ap_sample'
  VERIFIED_INDEX = 'index_external_resources_on_ap_item_verified'
  CANDIDATE_WHERE = 'source_deleted_at IS NULL AND activitypub_candidate_url IS NOT NULL'

  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      add_source_columns
      add_resource_columns
    end

    # Four columns so `ORDER BY activitypub_next_check_at, id LIMIT 2` is an
    # index range, including when every new candidate shares the epoch due time.
    safety_assured do
      add_index :external_resources, [:external_source_id, :activitypub_explicit, :activitypub_next_check_at, :id],
                where: CANDIDATE_WHERE, name: DUE_INDEX, algorithm: :concurrently, if_not_exists: true
    end
    add_index :external_resources, [:external_source_id, :activitypub_explicit, :id],
              where: CANDIDATE_WHERE, name: SAMPLE_INDEX, algorithm: :concurrently, if_not_exists: true
    add_index :external_resources, [:external_source_id],
              where: "activitypub_state = 'verified' AND source_deleted_at IS NULL",
              name: VERIFIED_INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :external_resources, name: VERIFIED_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :external_resources, name: SAMPLE_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :external_resources, name: DUE_INDEX, algorithm: :concurrently, if_exists: true

    safety_assured do
      execute "SET lock_timeout = '5s'"
      remove_resource_columns
      remove_source_columns
    end
  end

  private

  def add_source_columns
    add_column :external_sources, :activitypub_state, :string, null: false, default: 'unknown'
    add_column :external_sources, :activitypub_hint, :boolean, null: false, default: false
    add_column :external_sources, :activitypub_generator_hint, :boolean, null: false, default: false
    add_column :external_sources, :activitypub_feed_attribution, :string, null: false, default: 'unknown'
    add_column :external_sources, :host_activitypub_supported, :string, null: false, default: 'unknown'
    add_column :external_sources, :activitypub_instance_state, :string, null: false, default: 'unknown'
    add_column :external_sources, :activitypub_software, :string
    add_column :external_sources, :activitypub_instance_checked_at, :datetime
    add_column :external_sources, :activitypub_instance_next_check_at, :datetime
    add_column :external_sources, :activitypub_ordinary_blocked_until, :datetime
  end

  def add_resource_columns
    add_column :external_resources, :activitypub_state, :string, null: false, default: 'unknown'
    add_column :external_resources, :activitypub_candidate_url, :text
    add_column :external_resources, :activitypub_candidate_digest, :string, limit: 64
    add_column :external_resources, :activitypub_explicit, :boolean, null: false, default: false
    add_column :external_resources, :activitypub_evidence_version, :bigint, null: false, default: 0
    add_column :external_resources, :activitypub_object_id, :text
    add_column :external_resources, :activitypub_object_id_status, :string
    add_column :external_resources, :activitypub_object_type, :string
    add_column :external_resources, :activitypub_checked_at, :datetime
    add_column :external_resources, :activitypub_next_check_at, :datetime
  end

  def remove_source_columns
    %i(
      activitypub_ordinary_blocked_until
      activitypub_instance_next_check_at
      activitypub_instance_checked_at
      activitypub_software
      activitypub_instance_state
      host_activitypub_supported
      activitypub_feed_attribution
      activitypub_generator_hint
      activitypub_hint
      activitypub_state
    ).each do |column|
      remove_column :external_sources, column, if_exists: true
    end
  end

  def remove_resource_columns
    %i(
      activitypub_next_check_at
      activitypub_checked_at
      activitypub_object_type
      activitypub_object_id_status
      activitypub_object_id
      activitypub_evidence_version
      activitypub_explicit
      activitypub_candidate_digest
      activitypub_candidate_url
      activitypub_state
    ).each do |column|
      remove_column :external_resources, column, if_exists: true
    end
  end
end
