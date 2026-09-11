# frozen_string_literal: true

class ModerationEvidenceSnapshotPolicy < ApplicationPolicy
  def index?
    staff?
  end

  def show?
    staff?
  end
end
