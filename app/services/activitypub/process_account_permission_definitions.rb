# frozen_string_literal: true

module ActivityPub::ProcessAccountPermissionDefinitions
  private

  # canCreate and canView live on the Group actor document. Reading them
  # here does not fetch another document. A missing or unusable value is
  # stored as nil and the snapshot time still advances.
  def assign_group_permission_definitions!
    if @account.group?
      @account.can_create_affiliation = affiliation_identifier(@json['canCreate'])
      @account.can_view_affiliation = affiliation_identifier(@json['canView'])
      @account.permission_definitions_fetched_at = Time.now.utc
    else
      @account.can_create_affiliation = nil
      @account.can_view_affiliation = nil
      @account.permission_definitions_fetched_at = nil
    end
  end

  def affiliation_identifier(value)
    raw = value.is_a?(Hash) ? value_or_id(value) : value
    return unless raw.is_a?(String)

    identifier = raw.strip
    return if identifier.blank? || identifier.length > GroupAffiliation::RELATIONSHIP_MAX_LENGTH

    identifier
  end
end
