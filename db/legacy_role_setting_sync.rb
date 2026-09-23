# frozen_string_literal: true

# Final copy of the legacy invite and badge settings onto the default roles.
# Migration-local models only. Owner's invite permission comes from the
# administrator flag, so this sync never writes Owner's permissions.
module LegacyRoleSettingSync
  INVITE_USERS = 1 << 16
  SUPPORTED_MIN_INVITE_ROLES = %w(disabled user moderator admin).freeze
  INVITE_BITS = {
    'user' => { everyone: true, moderator: false, admin: false },
    'moderator' => { everyone: false, moderator: true, admin: true },
    'admin' => { everyone: false, moderator: false, admin: true },
    'disabled' => { everyone: false, moderator: false, admin: false },
  }.freeze

  class RoleRecord < ActiveRecord::Base
    self.table_name = 'user_roles'
  end

  class SettingRecord < ActiveRecord::Base
    self.table_name = 'settings'
  end

  def self.call
    min_invite_role = read_setting('min_invite_role', 'admin').to_s
    show_staff_badge = truthy?(read_setting('show_staff_badge', true))
    show_moderator_badge = truthy?(read_setting('show_moderator_badge', true))
    raise ArgumentError, "Unsupported min_invite_role: #{min_invite_role.inspect}" unless SUPPORTED_MIN_INVITE_ROLES.include?(min_invite_role)

    RoleRecord.transaction do
      everyone  = RoleRecord.lock.find_by!(id: -99)
      moderator = RoleRecord.lock.find_by!(name: 'Moderator')
      admin     = RoleRecord.lock.find_by!(name: 'Admin')
      owner     = RoleRecord.lock.find_by!(name: 'Owner')
      bits = INVITE_BITS.fetch(min_invite_role)

      assign!(everyone, permissions: with_invite(everyone.permissions, bits[:everyone]), highlighted: false)
      assign!(moderator, permissions: with_invite(moderator.permissions, bits[:moderator]), highlighted: show_moderator_badge)
      assign!(admin, permissions: with_invite(admin.permissions, bits[:admin]), highlighted: show_staff_badge)
      assign!(owner, highlighted: show_staff_badge)
    end

    true
  end

  def self.read_setting(var, default)
    raw = SettingRecord.where(thing_type: nil, thing_id: nil).find_by(var: var)&.read_attribute(:value)
    return default if raw.blank?

    YAML.safe_load(raw)
  end

  def self.truthy?(value)
    value == true || value.to_s == '1' || value.to_s == 'true'
  end

  def self.with_invite(permissions, enabled)
    permissions = permissions.to_i
    if enabled
      permissions | INVITE_USERS
    else
      permissions & ~INVITE_USERS
    end
  end

  def self.assign!(role, attributes)
    role.assign_attributes(attributes)
    return unless role.changed?

    role.updated_at = Time.current
    role.save!
  end

  private_class_method :read_setting, :truthy?, :with_invite, :assign!
end
