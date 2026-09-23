# frozen_string_literal: true

class CatchUpUserRoleIds < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  class User < ApplicationRecord
    self.table_name = 'users'
  end

  def up
    load Rails.root.join('db', 'seeds', '03_roles.rb')

    owner_role     = ::UserRole.find_by!(name: 'Owner')
    moderator_role = ::UserRole.find_by!(name: 'Moderator')

    User.where(admin: true).in_batches.update_all(role_id: owner_role.id)
    User.where(admin: false, moderator: true).in_batches.update_all(role_id: moderator_role.id)
    # Only default legacy roles are cleared. A custom role_id is left alone.
    User.where(admin: false, moderator: false, role_id: [owner_role.id, moderator_role.id]).in_batches.update_all(role_id: nil)
  end

  def down
    # no-op
  end
end
