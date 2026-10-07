# frozen_string_literal: true

class PostingContext::GroupPermissionEvidenceResolver
  SOURCE = 'fep-5219'
  AUTHORITY = 'protocol'
  NO_AFFILIATION = 'none'

  # Joins a fresh viewer affiliation snapshot with the Group's fresh
  # canCreate / canView identifiers. The identifier must match exactly.
  # A missing match is unknown, not a denial.
  def call(affiliation_evidence, definition_evidence)
    {
      create: permission(:can_create, affiliation_evidence, definition_evidence),
      view: permission(:can_view, affiliation_evidence, definition_evidence),
    }
  end

  private

  def permission(attribute, affiliation_evidence, definition_evidence)
    required = required_affiliation(attribute, affiliation_evidence, definition_evidence)
    return unknown if required.nil?
    return allowed(NO_AFFILIATION) if required == NO_AFFILIATION
    return unknown unless listed?(affiliation_evidence, required)

    allowed(required)
  end

  def required_affiliation(attribute, affiliation_evidence, definition_evidence)
    return unless fresh?(affiliation_evidence) && fresh?(definition_evidence)

    value = definition_evidence[attribute]
    return unless value.is_a?(String) && value.present?

    value
  end

  def fresh?(evidence)
    evidence.is_a?(Hash) && evidence[:snapshot_status] == 'fresh'
  end

  def listed?(affiliation_evidence, required)
    relationships = affiliation_evidence[:relationships]
    return false unless relationships.is_a?(Array)

    relationships.any? { |row| row.is_a?(Hash) && row[:relationship] == required }
  end

  def allowed(via_relationship)
    {
      status: 'allowed',
      source: SOURCE,
      via_relationship: via_relationship,
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
