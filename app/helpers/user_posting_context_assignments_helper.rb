# frozen_string_literal: true

module UserPostingContextAssignmentsHelper
  def user_posting_assignment_kind_label(assignment)
    t("user_posting_context_assignments.kinds.#{assignment.surface_kind}", default: assignment.surface_kind.to_s)
  end

  def user_posting_assignment_status_label(assignment)
    t("user_posting_context_assignments.availability.#{assignment.availability_status}", default: assignment.availability_status.to_s)
  end
end
