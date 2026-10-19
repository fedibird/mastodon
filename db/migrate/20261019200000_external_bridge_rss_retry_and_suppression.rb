# frozen_string_literal: true

# Per-subscription retry bookkeeping, per-owner deletion tombstones, and
# per-item projection failures. Shared source tables stay free of user ids.
class ExternalBridgeRSSRetryAndSuppression < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      add_column :external_subscriptions, :next_retry_at, :datetime
      add_column :external_subscriptions, :retry_count, :integer, null: false, default: 0
      add_column :external_subscriptions, :failed_item_count, :integer, null: false, default: 0
    end

    create_table :external_projection_suppressions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :external_resource, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.timestamps
    end
    add_index :external_projection_suppressions, [:user_id, :external_resource_id], unique: true, name: 'index_external_projection_suppressions_on_user_and_resource'

    create_table :external_projection_failures do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :external_subscription, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :external_resource, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :error_code, null: false
      t.timestamps
    end
    add_index :external_projection_failures, [:user_id, :external_resource_id], unique: true, name: 'index_external_projection_failures_on_user_and_resource'
    add_index :external_projection_failures, :external_subscription_id, name: 'index_external_projection_failures_on_subscription'
  end

  def down
    drop_table :external_projection_failures
    drop_table :external_projection_suppressions
    safety_assured do
      remove_column :external_subscriptions, :failed_item_count
      remove_column :external_subscriptions, :retry_count
      remove_column :external_subscriptions, :next_retry_at
    end
  end
end
