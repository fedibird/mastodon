# frozen_string_literal: true

class SyncLegacySettingsToUserRoles < ActiveRecord::Migration[6.1]
  def up
    # Same implementation the admin form and seeds use, so a one-shot migrate
    # cannot drift from later dual-writes. Missing default roles raise.
    UserRole::LegacySettingsSync.call
  end

  def down
    # no-op: previous invite bits and highlighted flags are not recoverable
  end
end
