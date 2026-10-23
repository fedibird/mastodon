# frozen_string_literal: true

# User-owned delivery routes for an existing external subscription.
# Adds one column and one unique key on the small subscriptions table so a
# route cannot name another user's subscription. No statuses rewrite.
class CreateExternalFeedRoutes < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_column :external_subscriptions, :feed_routes_revision, :bigint, null: false, default: 0
      add_index :external_subscriptions, [:id, :user_id], unique: true, name: 'index_external_subscriptions_on_id_and_user'

      create_table :external_feed_routes do |t|
        t.bigint :user_id, null: false
        t.bigint :external_subscription_id, null: false
        t.string :destination, null: false
        t.bigint :list_id
        t.timestamps
      end
      add_index :external_feed_routes, :list_id, name: 'index_external_feed_routes_on_list_id'
      add_foreign_key :external_feed_routes, :users, column: :user_id, on_delete: :cascade, name: 'fk_external_feed_routes_user'
      add_foreign_key :external_feed_routes, :lists, column: :list_id, on_delete: :cascade, name: 'fk_external_feed_routes_list'

      add_check_constraint :external_feed_routes,
                           "(destination = 'home' AND list_id IS NULL) OR (destination = 'list' AND list_id IS NOT NULL)",
                           name: 'external_feed_routes_destination_shape'
      add_index :external_feed_routes, [:user_id, :external_subscription_id],
                unique: true,
                where: "destination = 'home' AND list_id IS NULL",
                name: 'index_external_feed_routes_on_home'
      add_index :external_feed_routes, [:user_id, :external_subscription_id, :list_id],
                unique: true,
                where: "destination = 'list' AND list_id IS NOT NULL",
                name: 'index_external_feed_routes_on_list'
      execute ExternalBridge::Schema::FEED_ROUTE_SQL
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      execute <<~SQL
        DROP TRIGGER IF EXISTS lists_external_feed_routes_account_guard ON lists;
        DROP TRIGGER IF EXISTS external_feed_routes_enforce_list_owner ON external_feed_routes;
        ALTER TABLE external_feed_routes DROP CONSTRAINT IF EXISTS fk_external_feed_routes_subscription_owner;
      SQL
      drop_table :external_feed_routes, if_exists: true
      execute <<~SQL
        DROP FUNCTION IF EXISTS lists_external_feed_routes_account_guard();
        DROP FUNCTION IF EXISTS external_feed_routes_enforce_list_owner();
      SQL
      remove_index :external_subscriptions, name: 'index_external_subscriptions_on_id_and_user'
      remove_column :external_subscriptions, :feed_routes_revision
    end
  end
end
