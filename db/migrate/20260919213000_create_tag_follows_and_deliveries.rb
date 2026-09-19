# frozen_string_literal: true

class CreateTagFollowsAndDeliveries < ActiveRecord::Migration[6.1]
  def change
    create_table :tag_follows do |t|
      t.belongs_to :tag, null: false, foreign_key: { on_delete: :cascade }
      t.belongs_to :account, null: false, foreign_key: { on_delete: :cascade }, index: false

      t.timestamps
    end

    add_index :tag_follows, [:account_id, :tag_id], unique: true

    create_table :tag_follow_deliveries do |t|
      t.belongs_to :tag_follow, null: false, foreign_key: { on_delete: :cascade }
      t.belongs_to :list, null: true, foreign_key: { on_delete: :cascade }
      t.boolean :media_only, null: false, default: false

      t.timestamps
    end

    add_index :tag_follow_deliveries,
              :tag_follow_id,
              unique: true,
              where: 'list_id IS NULL',
              name: 'index_tag_follow_deliveries_on_home'

    add_index :tag_follow_deliveries,
              [:tag_follow_id, :list_id],
              unique: true,
              where: 'list_id IS NOT NULL',
              name: 'index_tag_follow_deliveries_on_list'
  end
end
