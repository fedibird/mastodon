# frozen_string_literal: true

# Outstanding ordinary probe slots are unchecked candidate rows. This partial
# index keeps that count on a small range after a feed has checked a long
# history. Checked rows are excluded, so they do not keep a slot forever.
#
# CREATE INDEX CONCURRENTLY uses lock_timeout = 0 (wait for the brief
# ShareUpdateExclusiveLock, do not block readers and writers). The session
# default is restored in ensure. disable_ddl_transaction! means SET LOCAL
# would not cover the index build.
class AddExternalRSSActivityPubUncheckedIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_external_resources_on_ap_unchecked'
  UNCHECKED_WHERE = 'source_deleted_at IS NULL AND activitypub_candidate_url IS NOT NULL AND activitypub_checked_at IS NULL'

  def up
    safety_assured do
      execute 'SET lock_timeout TO 0'
      add_index :external_resources, [:external_source_id, :activitypub_explicit, :id],
                where: UNCHECKED_WHERE, name: INDEX_NAME, algorithm: :concurrently, if_not_exists: true
    ensure
      execute 'SET lock_timeout TO DEFAULT'
    end
  end

  def down
    safety_assured do
      execute 'SET lock_timeout TO 0'
      remove_index :external_resources, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    ensure
      execute 'SET lock_timeout TO DEFAULT'
    end
  end
end
