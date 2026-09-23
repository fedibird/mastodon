# frozen_string_literal: true

module UserRoles
  extend ActiveSupport::Concern

  included do
    # `User#role` stays the legacy string API. This association is the Role
    # record behind role_id and must not assign through that setter.
    belongs_to :assigned_role, class_name: 'UserRole', foreign_key: :role_id, optional: true, inverse_of: :users

    scope :admins, -> { where(admin: true) }
    scope :moderators, -> { where(moderator: true) }
    scope :staff, -> { admins.or(moderators) }
    # role_id nil is Everyone. Include those users when Everyone itself can.
    scope :those_who_can, lambda { |*privileges|
      matching_roles = UserRole.that_can(*privileges)
      relation = where(role_id: matching_roles.map(&:id))
      relation = relation.or(where(role_id: nil)) if matching_roles.any?(&:everyone?)
      relation
    }

    before_validation :sync_role_id_from_legacy_booleans, if: :sync_legacy_role_id?
  end

  def staff?
    admin? || moderator?
  end

  def role=(value)
    case value
    when 'admin'
      self.admin     = true
      self.moderator = false
    when 'moderator'
      self.admin     = false
      self.moderator = true
    else
      self.admin     = false
      self.moderator = false
    end
  end

  def role
    if admin?
      'admin'
    elsif moderator?
      'moderator'
    else
      'user'
    end
  end

  def role?(role)
    case role
    when 'user'
      true
    when 'moderator'
      staff?
    when 'admin'
      admin?
    else
      false
    end
  end

  # UserPolicy authorizes this. Admin::RolesController is the only application caller.
  def promote!
    if moderator?
      update!(moderator: false, admin: true)
    elsif !admin?
      update!(moderator: true)
    end
  end

  def demote!
    if admin?
      update!(admin: false, moderator: true)
    elsif moderator?
      update!(moderator: false)
    end
  end

  def user_role
    assigned_role || UserRole.everyone
  end

  def user_role=(role)
    case legacy_assignable_role(role)
    when :owner
      self.admin = true
      self.moderator = false
      self.role_id = UserRole.find_by(name: 'Owner')&.id
    when :moderator
      self.admin = false
      self.moderator = true
      self.role_id = UserRole.find_by(name: 'Moderator')&.id
    when :everyone
      self.admin = false
      self.moderator = false
      self.role_id = nil
    else
      raise ArgumentError, 'Only Owner, Moderator, and Everyone can be assigned through the legacy role bridge'
    end
  end

  def can?(*permissions)
    user_role.can?(*permissions)
  end

  def administrative?
    functional? && user_role.administrative?
  end

  # DM and notification bypass for moderation staff. Broader administrative
  # permissions such as view_devops must not skip block, mute, or DM limits.
  def moderation_staff?
    functional? && can?(:manage_users, :manage_reports)
  end

  private

  def legacy_assignable_role(role)
    return :everyone if role.nil? || role.everyone?

    case role.name
    when 'Owner'
      :owner
    when 'Moderator'
      :moderator
    else
      :unsupported
    end
  end

  def sync_legacy_role_id?
    new_record? || will_save_change_to_admin? || will_save_change_to_moderator?
  end

  def sync_role_id_from_legacy_booleans
    self.role_id = if admin?
                     UserRole.find_by(name: 'Owner')&.id
                   elsif moderator?
                     UserRole.find_by(name: 'Moderator')&.id
                   end
  end
end
