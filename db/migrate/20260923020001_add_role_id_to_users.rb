# frozen_string_literal: true

class AddRoleIdToUsers < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      add_reference :users, :role, foreign_key: { to_table: 'user_roles', on_delete: :nullify }, index: false
    end

    add_index :users, :role_id, algorithm: :concurrently, where: 'role_id IS NOT NULL', name: :index_users_on_role_id
  end

  def down
    remove_index :users, name: :index_users_on_role_id, algorithm: :concurrently
    safety_assured { remove_reference :users, :role, foreign_key: { to_table: 'user_roles' } }
  end
end
