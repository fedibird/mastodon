# frozen_string_literal: true

# Ensures the default Owner, Admin, and Moderator roles exist.
#
# It does not rewrite users.role_id. After the earlier backfills, role_id is
# the runtime source of truth and the legacy admin/moderator booleans stay as
# history. The admin UI and tootctl change only role_id, and admin action logs
# are not a reliable record: tootctl does not write one, and logs can be
# removed. A row with admin=true and role Owner or Admin can therefore be
# either the old backfill or a later explicit choice. Rewriting it from
# FEDIBIRD_HOSTED would raise or drop permissions without a way to tell those
# cases apart.
#
# Hosted deployments that still want legacy admins moved from Owner to Admin
# run `tootctl accounts legacy_admin_roles` and, after reading the counts,
# pass --reassign-to-admin. That command can overwrite an explicit Owner.
class DistinguishLegacyAdminUserRoles < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    load Rails.root.join('db', 'seeds', '03_roles.rb')
  end

  def down
    # no-op
  end
end
