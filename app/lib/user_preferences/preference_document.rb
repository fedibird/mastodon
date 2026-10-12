# frozen_string_literal: true

# JSON document for the signed-in user's preferences.
# One Reader loads every published key. Values are not rewritten in storage.
class UserPreferences::PreferenceDocument
  VERSION = 1
  JSON_SCALARS = [NilClass, TrueClass, FalseClass, Integer, String].freeze

  def initialize(user)
    @values = UserPreferences::Reader.new(user).read
  end

  def as_json(*)
    {
      version: VERSION,
      preferences: @values.each_with_object({}) do |(key, value), document|
        definition = UserPreferences::Schema.get(key)
        document[definition.api_key_candidate] = entry(definition, value)
      end,
    }
  end

  private

  def entry(definition, value)
    check = definition.check(value)
    errors = type_errors(check)
    configured = json_scalar(value.configured, 'configured', errors)
    effective = json_scalar(value.effective, 'effective', errors)
    public_value = public_json(value, check, errors)
    {
      key: definition.api_key_candidate,
      state: value.state.to_s,
      configured: configured,
      effective: effective,
      public_value: public_value,
      public_valid: check.public_match? && errors.none? { |error| error[:field] == 'public_value' },
      validation_errors: errors,
    }
  end

  def public_json(value, check, errors)
    return nil unless check.public_match?

    json_scalar(value.public_value, 'public_value', errors)
  end

  def type_errors(check)
    check.mismatches.map do |item|
      {
        field: item[:field].to_s,
        expected: item[:expected].map(&:to_s),
        actual: item[:actual].to_s,
      }
    end
  end

  def json_scalar(value, field, errors)
    return value if JSON_SCALARS.any? { |type| value.is_a?(type) }

    errors << { field: field, expected: ['json_scalar'], actual: 'unsupported' }
    nil
  end
end
