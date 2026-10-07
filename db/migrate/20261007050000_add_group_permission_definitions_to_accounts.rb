# frozen_string_literal: true

class AddGroupPermissionDefinitionsToAccounts < ActiveRecord::Migration[6.1]
  def change
    add_column :accounts, :can_create_affiliation, :string
    add_column :accounts, :can_view_affiliation, :string
    add_column :accounts, :permission_definitions_fetched_at, :datetime
  end
end
