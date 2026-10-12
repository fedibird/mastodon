# frozen_string_literal: true

# Public metadata for the published preference keys.
# Internal paths and user-specific values are not included.
class UserPreferences::SchemaDocument
  VERSION = 1

  def as_json(*)
    {
      version: VERSION,
      schema: UserPreferences::Schema.all.map { |definition| entry(definition) },
    }
  end

  private

  def entry(definition)
    {
      key: definition.api_key_candidate,
      category: definition.category.to_s,
      owner: definition.owner.to_s,
      configured_type: strings(definition.configured_type),
      effective_type: strings(definition.effective_type),
      public_type: strings(definition.public_type),
      allowed_values: definition.allowed_values,
      ui_range: definition.ui_range&.transform_keys(&:to_s),
      default_source: definition.default_source,
      dependencies: definition.dependencies,
      read_policy: definition.read_policy.to_s,
      write_policy: definition.write_policy.to_s,
      apply_hint: definition.apply_hint.to_s,
      legacy_formats: definition.legacy_formats.map { |item| json_legacy(item) },
    }
  end

  def strings(value)
    return nil if value.nil?

    value.map(&:to_s)
  end

  def json_legacy(item)
    item.is_a?(Symbol) ? item.to_s : item
  end
end
