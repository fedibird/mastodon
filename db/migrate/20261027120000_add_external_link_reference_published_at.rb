# frozen_string_literal: true

# Durable publish mark for an E4 reference. The Redis key written by
# PublishStatusService expires after 7 days and is not reused as the
# "already distributed" decision. published_at stays null until that service
# returns, so a crash before distribution can be retried. A later reuse does
# not enqueue distribution again.
class AddExternalLinkReferencePublishedAt < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      unless column_exists?(:external_projection_link_references, :published_at)
        add_column :external_projection_link_references, :published_at, :datetime
      end
      execute ExternalBridge::Schema::LINK_REFERENCE_SQL
      execute ExternalBridge::Schema::LINK_REFERENCE_PUBLISH_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute ExternalBridge::Schema::LINK_SHARING_ROLLBACK_FLOOR_SQL
      execute <<~SQL
        DROP TRIGGER IF EXISTS external_projection_link_references_publish_mark ON external_projection_link_references;
        DROP FUNCTION IF EXISTS external_projection_link_references_publish_mark();
      SQL
      if column_exists?(:external_projection_link_references, :published_at)
        remove_column :external_projection_link_references, :published_at
      end
    end
  end
end
