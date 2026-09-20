# frozen_string_literal: true

class AddLegacyFollowTagIdToTagFollowDeliveries < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    add_column :tag_follow_deliveries, :legacy_follow_tag_id, :bigint

    add_index :tag_follow_deliveries, :legacy_follow_tag_id,
              unique: true,
              algorithm: :concurrently,
              name: :index_tag_follow_deliveries_on_legacy_follow_tag_id
  end

  def down
    remove_index :tag_follow_deliveries,
                 name: :index_tag_follow_deliveries_on_legacy_follow_tag_id,
                 algorithm: :concurrently
    remove_column :tag_follow_deliveries, :legacy_follow_tag_id
  end
end
