# frozen_string_literal: true

# Corrects the Owner assignment that earlier backfills gave every legacy
# admin. FEDIBIRD_HOSTED is read only while this migration runs:
# "true" assigns Admin, anything else (including unset) assigns Owner.
# Changing the variable afterwards does not rewrite role_id.
class DistinguishLegacyAdminUserRoles < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  class User < ApplicationRecord
    self.table_name = 'users'
  end

  def up
    load Rails.root.join('db', 'seeds', '03_roles.rb')

    owner_role     = ::UserRole.find_by!(name: 'Owner')
    admin_role     = ::UserRole.find_by!(name: 'Admin')
    moderator_role = ::UserRole.find_by!(name: 'Moderator')
    legacy_admin_role = ENV['FEDIBIRD_HOSTED'] == 'true' ? admin_role : owner_role

    # Earlier backfills wrote Owner or left role_id nil. Admin is included so a
    # hosted run can be applied again without missing rows it already moved.
    # Any other role_id is an explicit assignment and is left alone.
    User.where(admin: true, role_id: [nil, admin_role.id, owner_role.id]).in_batches.update_all(role_id: legacy_admin_role.id)
    User.where(admin: false, moderator: true, role_id: [nil, moderator_role.id]).in_batches.update_all(role_id: moderator_role.id)
  end

  def down
    # no-op
  end
end
