# frozen_string_literal: true

module Admin::GroupAdministrationHelper
  def group_admin_yes_no(value)
    t(value ? 'admin.group_administration.yes' : 'admin.group_administration.no')
  end

  def group_creation_state_label(state)
    t("admin.group_creation_requests.states.#{state}")
  end

  def group_creation_requester_ready?(request)
    GroupManagement.local_functional_person?(request.requester_account)
  end

  def group_creation_handoff_state(request)
    return :absent if request.nil? || request.icon_storage_key.blank?
    return :purged if request.icon_purged_at.present?
    return :staged unless request.approved?
    return :copied if request.icon_handoff_copied_at.present?
    return :exhausted if request.icon_handoff_attempts.to_i >= GroupCreationIcons::Copy::MAX_ATTEMPTS
    return :failed if request.icon_handoff_error.present?

    :pending
  end

  def group_creation_icon_retryable?(request)
    request&.approved? && request.icon_storage_key.present? && request.icon_purged_at.nil?
  end

  def group_admin_audit_code(log)
    changes = log.recorded_changes
    return unless changes.is_a?(Hash)

    code = changes['code'].to_s
    code if code.match?(/\A[a-z0-9_]{1,64}\z/)
  end

  def managed_group_owner(managed_group)
    managed_group.role_assignments.find { |assignment| assignment.owner? && assignment.revoked_at.nil? }
  end
end
