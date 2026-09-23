# frozen_string_literal: true

module UserRoles
  extend ActiveSupport::Concern

  included do
    # role_id nil is Everyone. The reader below returns that role instead of nil.
    belongs_to :role, class_name: 'UserRole', inverse_of: :users, optional: true

    # Include role_id nil users when Everyone itself can. Other roles match by id.
    scope :those_who_can, lambda { |*privileges|
      matching_roles = UserRole.that_can(*privileges)
      relation = where(role_id: matching_roles.map(&:id))
      relation = relation.or(where(role_id: nil)) if matching_roles.any?(&:everyone?)
      relation
    }

    attr_writer :current_account

    validate :validate_role_elevation

    delegate :can?, to: :role

    # Defined on the model so it replaces the association reader. `super`
    # still reaches the generated association method.
    def role
      if role_id.nil?
        UserRole.everyone
      else
        super
      end
    end
  end

  # role_id is the only assignment. Legacy admin/moderator columns are left
  # untouched, including when the destination is Everyone.
  def assign_user_role!(new_role, current_account:)
    self.current_account = current_account
    self.role_id = new_role.nil? || new_role.everyone? ? nil : new_role.id
    association(:role).reset

    if save
      true
    else
      restore_attributes
      association(:role).reset
      false
    end
  end

  def administrative?
    functional? && role.administrative?
  end

  # DM and notification bypass for moderation staff. Broader administrative
  # permissions such as view_devops must not skip block, mute, or DM limits.
  def moderation_staff?
    functional? && role.can?(:manage_users, :manage_reports)
  end

  private

  # Runs when an actor is attached. Equal position is allowed because
  # UserRole#overrides? is strict. An unrelated save does not set
  # current_account, so it does not treat the existing role as elevation.
  def validate_role_elevation
    return unless defined?(@current_account) && @current_account

    errors.add(:role_id, :elevated) if role&.overrides?(@current_account.user&.role)
  end
end
