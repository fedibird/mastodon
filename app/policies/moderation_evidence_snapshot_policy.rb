# frozen_string_literal: true

class ModerationEvidenceSnapshotPolicy < ApplicationPolicy
  def index?
    role.can?(:manage_reports)
  end

  def show?
    role.can?(:manage_reports)
  end
end
