# frozen_string_literal: true

require_relative '../legacy_role_setting_sync'

class SyncLegacySettingsToUserRoles < ActiveRecord::Migration[6.1]
  def up
    # Same data result as the removed UserRole::LegacySettingsSync service.
    # Inlined so a fresh migrate does not depend on that application class.
    LegacyRoleSettingSync.call
  end

  def down
    # no-op: previous invite bits and highlighted flags are not recoverable
  end
end
