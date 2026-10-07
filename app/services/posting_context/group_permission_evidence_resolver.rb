# frozen_string_literal: true

class PostingContext::GroupPermissionEvidenceResolver
  SOURCE = 'fep-5219'
  AUTHORITY = 'protocol'
  STANDARD_ADMIN = 'admin'

  # Reads affiliation evidence only. The FEP-5219 standard affiliation
  # "admin" is the sole positive create signal, matched exactly.
  # Every other snapshot is unknown. Unknown is not a denial.
  def call(affiliation_evidence)
    {
      create: create_permission(affiliation_evidence),
    }
  end

  private

  def create_permission(evidence)
    return unknown unless fresh_admin?(evidence)

    allowed
  end

  def fresh_admin?(evidence)
    return false unless evidence.is_a?(Hash) && evidence[:snapshot_status] == 'fresh'
    return false unless evidence[:relationships].is_a?(Array)

    evidence[:relationships].any? { |row| row.is_a?(Hash) && row[:relationship] == STANDARD_ADMIN }
  end

  def allowed
    {
      status: 'allowed',
      source: SOURCE,
      via_relationship: STANDARD_ADMIN,
      authority: AUTHORITY,
    }
  end

  def unknown
    {
      status: 'unknown',
      source: SOURCE,
      via_relationship: nil,
      authority: AUTHORITY,
    }
  end
end
