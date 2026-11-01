# frozen_string_literal: true

module GroupRoles
  # Role changes are serialized on the group's management row. They do not
  # change Follow records, GroupAffiliation, or server-wide user permissions.
  class Moderators
    def self.appoint(managed_group:, actor_account:, target_account:)
      new(managed_group, actor_account).change(:appoint, target_account)
    end

    def self.revoke(managed_group:, actor_account:, target_account_id:)
      new(managed_group, actor_account).change(:revoke, target_account_id)
    end

    def self.resign(managed_group:, actor_account:)
      new(managed_group, actor_account).change(:resign, actor_account&.id)
    end

    def initialize(managed_group, actor_account)
      @managed_group = managed_group
      @actor_account = actor_account
    end

    def change(action, target)
      return :not_authorized unless GroupManagement.local_functional_person?(@actor_account)

      ManagedGroup.transaction do
        managed = ManagedGroup.lock.find(@managed_group.id)
        next :unmanaged unless managed.approved_request? && managed.creation_request&.approved?

        actor_role = GroupRoleAssignment.active.find_by(group_account_id: managed.account_id, member_account_id: @actor_account.id)
        next :not_authorized unless allowed?(action, actor_role)

        action == :appoint ? appoint(managed, target) : revoke(managed, action, target)
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      :conflict
    rescue GroupAdministration::Audit::Error
      :audit_failed
    end

    private

    def allowed?(action, actor_role)
      return actor_role&.owner? if action != :resign

      actor_role&.moderator?
    end

    def appoint(managed, target)
      return :invalid_target unless GroupManagement.local_functional_person?(target)

      active = GroupRoleAssignment.active.find_by(group_account_id: managed.account_id, member_account_id: target.id)
      return :already_assigned if active

      assignment = GroupRoleAssignment.create!(
        group_account_id: managed.account_id,
        member_account: target,
        role: :moderator,
        granted_by_account: @actor_account
      )
      audit!(:appoint_group_moderator, managed, assignment)
      :appointed
    end

    def revoke(managed, action, target_id)
      assignment = GroupRoleAssignment.active.moderator.find_by(
        group_account_id: managed.account_id,
        member_account_id: target_id
      )
      return :not_found unless assignment

      assignment.revoke!
      audit!(action == :resign ? :resign_group_moderator : :revoke_group_moderator, managed, assignment)
      action == :resign ? :resigned : :revoked
    end

    def audit!(action, managed, assignment)
      GroupAdministration::Audit.record!(
        account: @actor_account,
        action: action,
        target: managed,
        changes: { 'role_assignment_id' => assignment.id, 'member_account_id' => assignment.member_account_id }
      )
    end
  end
end
