# frozen_string_literal: true

# Speeds the group directory's candidate set. The predicate matches
# Account.discoverable.groups before viewer, search, and software filters.
# Remote NodeInfo checks stay a subquery so this index does not join nodes.
class AddDiscoverableGroupDirectoryIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  INDEX_NAME = :index_accounts_on_discoverable_groups
  INDEX_WHERE = <<~SQL.squish.freeze
    actor_type = 'Group'
    AND discoverable = TRUE
    AND suspended_at IS NULL
    AND silenced_at IS NULL
    AND moved_to_account_id IS NULL
  SQL

  def up
    safety_assured do
      add_index :accounts, :id,
                order: { id: :desc },
                where: INDEX_WHERE,
                algorithm: :concurrently,
                name: INDEX_NAME,
                if_not_exists: true
    end
  end

  def down
    remove_index :accounts, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
