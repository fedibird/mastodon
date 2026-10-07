# frozen_string_literal: true

class PostingContext::GroupPermissionEvidenceResolver
  SOURCE = 'fep-5219'
  AUTHORITY = 'protocol'
  NO_AFFILIATION = 'none'

  # Joins a fresh canCreate / canView identifier with the viewer's
  # affiliations. none means no affiliation is required, so that result
  # does not depend on the affiliation snapshot. Any other identifier
  # must match a fresh snapshot exactly. A missing match is unknown.
  def call(affiliation_evidence, definition_evidence)
    {
      create: permission(:can_create, affiliation_evidence, definition_evidence),
      view: permission(:can_view, affiliation_evidence, definition_evidence),
    }
  end

  private

  def permission(attribute, affiliation_evidence, definition_evidence)
    required = required_affiliation(attribute, definition_evidence)
    return unknown if required.nil?
    return allowed(NO_AFFILIATION) if required == NO_AFFILIATION
    return unknown unless fresh?(affiliation_evidence) && listed?(affiliation_evidence, required)

    allowed(required)
  end

  def required_affiliation(attribute, definition_evidence)
    return unless fresh?(definition_evidence)

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
