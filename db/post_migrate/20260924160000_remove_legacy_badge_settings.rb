# frozen_string_literal: true

# Drops the global badge settings after FinalizeLegacySettingsOnUserRoles
# has copied them onto UserRole#highlighted. Scoped rows are left alone.
class RemoveLegacyBadgeSettings < ActiveRecord::Migration[6.1]
  class SettingRecord < ActiveRecord::Base
    self.table_name = 'settings'
  end

  def up
    SettingRecord.where(
      thing_type: nil,
      thing_id: nil,
      var: %w(show_staff_badge show_moderator_badge)
    ).delete_all
  end

  def down
    # no-op: the previous values were already copied and are not recoverable
  end
end
