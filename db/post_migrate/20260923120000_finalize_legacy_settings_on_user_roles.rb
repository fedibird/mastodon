# frozen_string_literal: true

require_relative '../legacy_role_setting_sync'

# Last time the stored invite and badge settings are copied onto roles.
# After this migration, runtime authorization does not read those settings.
# min_invite_role "disabled" clears invite_users on Everyone, Moderator, and
# Admin. Owner still invites because the administrator flag expands to every
# permission.
class FinalizeLegacySettingsOnUserRoles < ActiveRecord::Migration[6.1]
  def up
    LegacyRoleSettingSync.call
  end

  def down
    # no-op: previous invite bits and highlighted flags are not recoverable
  end
end
