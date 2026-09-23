# frozen_string_literal: true

# Mirrors the still-writable legacy invite and badge settings onto the default
# UserRole rows. Custom roles are never read or updated.
#
# Owner#can?(:invite_users) stays true because the administrator flag expands
# computed permissions to every flag. That does not mean Owner may invite when
# min_invite_role is "disabled": Fedibird treats that value as "nobody,
# including admins, may invite". #165 must keep a compatibility guard
# (`return false if Setting.min_invite_role == 'disabled'`) when InvitePolicy
# starts reading roles. This class does not change InvitePolicy.
class UserRole::LegacySettingsSync
  INVITE_USERS = UserRole::FLAGS[:invite_users]
  SUPPORTED_MIN_INVITE_ROLES = %w(disabled user moderator admin).freeze

  # Own invite_users bits. Moderator and Admin inherit Everyone, so "user"
  # leaves their own bits off. Owner is omitted: administrator already grants
  # every permission, and this sync does not depend on an Owner bit.
  INVITE_BITS = {
    'user' => { everyone: true, moderator: false, admin: false },
    'moderator' => { everyone: false, moderator: true, admin: true },
    'admin' => { everyone: false, moderator: false, admin: true },
    'disabled' => { everyone: false, moderator: false, admin: false },
  }.freeze

  def self.call(min_invite_role: Setting.min_invite_role, show_staff_badge: Setting.show_staff_badge, show_moderator_badge: Setting.show_moderator_badge)
    new(
      min_invite_role: min_invite_role,
      show_staff_badge: show_staff_badge,
      show_moderator_badge: show_moderator_badge
    ).call
  end

  def initialize(min_invite_role:, show_staff_badge:, show_moderator_badge:)
    @min_invite_role = min_invite_role.to_s
    @show_staff_badge = highlighted?(show_staff_badge)
    @show_moderator_badge = highlighted?(show_moderator_badge)
  end

  def call
    raise ArgumentError, "Unsupported min_invite_role: #{@min_invite_role.inspect}" unless SUPPORTED_MIN_INVITE_ROLES.include?(@min_invite_role)

    UserRole.transaction do
      everyone  = UserRole.lock.find_by!(id: -99)
      moderator = UserRole.lock.find_by!(name: 'Moderator')
      admin     = UserRole.lock.find_by!(name: 'Admin')
      owner     = UserRole.lock.find_by!(name: 'Owner')

      invite_bits = INVITE_BITS.fetch(@min_invite_role)
      assign!(everyone, permissions: permissions_with_invite(everyone, invite_bits[:everyone]), highlighted: false)
      assign!(moderator, permissions: permissions_with_invite(moderator, invite_bits[:moderator]), highlighted: @show_moderator_badge)
      assign!(admin, permissions: permissions_with_invite(admin, invite_bits[:admin]), highlighted: @show_staff_badge)
      assign!(owner, highlighted: @show_staff_badge)
    end

    true
  end

  private

  def highlighted?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def permissions_with_invite(role, enabled)
    if enabled
      role.permissions | INVITE_USERS
    else
      role.permissions & ~INVITE_USERS
    end
  end

  def assign!(role, attributes)
    role.assign_attributes(attributes)
    return unless role.changed?

    role.allow_legacy_settings_sync!
    role.instance_variable_set(:@computed_permissions, nil)
    role.save!
  end
end
