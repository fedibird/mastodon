# frozen_string_literal: true

class BackfillUserRoleIds < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  class User < ApplicationRecord
    self.table_name = 'users'
  end

  def up
    load Rails.root.join('db', 'seeds', '03_roles.rb')

    owner_role     = ::UserRole.find_by!(name: 'Owner')
    moderator_role = ::UserRole.find_by!(name: 'Moderator')

    # Admin wins when a legacy row has both flags. Do not apply the moderator
    # update to those rows, or they would be downgraded after the owner write.
    User.where(admin: true).in_batches.update_all(role_id: owner_role.id)
    User.where(admin: false, moderator: true).in_batches.update_all(role_id: moderator_role.id)
  end

  def down
    User.in_batches.update_all(role_id: nil)
  end
end
