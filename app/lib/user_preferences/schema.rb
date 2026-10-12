# frozen_string_literal: true

# Static metadata for the P1-1 preference keys.
# User-specific values come from UserPreferences::Reader. This class does not
# load docs/settings_service/catalog.yml and does not authorize a caller.
class UserPreferences::Schema
  EXTERNAL_DEPENDENCIES = %w(account.locked user.locale request_locale).freeze
  CATEGORIES = %i(posting translation appearance).freeze
  POLICIES = %i(general read_only).freeze
  APPLY_HINTS = %i(live reinitialize reload unknown).freeze
  TYPE_NAMES = %i(nil boolean string integer).freeze

  class << self
    def keys
      registry.keys.freeze
    end

    def get(key)
      name = key.to_s
      registry.fetch(name) { raise UserPreferences::UnsupportedKey, name }
    end

    def all
      registry.values.freeze
    end

    def validate_structure!
      validate_structure(registry)
      true
    end

    private

    def registry
      return @registry if defined?(@registry)

      built = UserPreferences::Definition.build_registry
      validate_structure(built)
      @registry = built.freeze
    end

    def validate_structure(definitions)
      names = definitions.keys
      unless names == UserPreferences::Reader::KEYS
        raise ArgumentError, 'schema keys do not match UserPreferences::Reader::KEYS'
      end
      unless names.select { |name| definitions[name].derived } == UserPreferences::Reader::DERIVED_KEYS
        raise ArgumentError, 'derived keys do not match UserPreferences::Reader::DERIVED_KEYS'
      end
      unless names.reject { |name| definitions[name].derived } == UserPreferences::Reader::STORAGE_KEYS
        raise ArgumentError, 'storage keys do not match UserPreferences::Reader::STORAGE_KEYS'
      end

      definitions.each_value { |definition| validate_definition(definition, names) }
    end

    def validate_definition(definition, names)
      raise ArgumentError, "#{definition.key} category" unless CATEGORIES.include?(definition.category)
      raise ArgumentError, "#{definition.key} owner" unless definition.owner == :user
      raise ArgumentError, "#{definition.key} read_policy" unless definition.read_policy == :general
      raise ArgumentError, "#{definition.key} write_policy" unless POLICIES.include?(definition.write_policy)
      raise ArgumentError, "#{definition.key} apply_hint" unless APPLY_HINTS.include?(definition.apply_hint)
      raise ArgumentError, "#{definition.key} api key is not marked as a candidate" unless definition.api_key_candidate.start_with?('user.')

      if definition.derived
        raise ArgumentError, "#{definition.key} derived storage" unless definition.storage_key.nil? && definition.configured_type.nil?
        raise ArgumentError, "#{definition.key} derived must be read only" unless definition.write_policy == :read_only
      else
        raise ArgumentError, "#{definition.key} storage_key" unless definition.storage_key == definition.key
        raise ArgumentError, "#{definition.key} configured_type" unless type_list?(definition.configured_type)
      end

      raise ArgumentError, "#{definition.key} effective_type" unless type_list?(definition.effective_type)
      raise ArgumentError, "#{definition.key} public_type" unless type_list?(definition.public_type)

      choices = definition.allowed_values
      if choices
        choices.each do |choice|
          type_name = UserPreferences::Conformance.ruby_type(choice)
          unless definition.public_type.include?(type_name)
            raise ArgumentError, "#{definition.key} choice #{choice.inspect} is not a public type"
          end
        end
      end

      if definition.key == 'translation_preferred_mode' && choices.include?('original')
        raise ArgumentError, 'original is not a stored translation mode'
      end

      if definition.key == 'default_privacy'
        raise ArgumentError, 'default_privacy choices drifted from Status.selectable_visibilities' unless choices == Status.selectable_visibilities
        raise ArgumentError, 'default_privacy form choices include a hidden visibility' if (choices & %w(direct limited)).any?
      end

      definition.dependencies.each do |dependency|
        next if names.include?(dependency) || EXTERNAL_DEPENDENCIES.include?(dependency)

        raise ArgumentError, "#{definition.key} dependency #{dependency} is not declared"
      end

      if definition.ui_range
        raise ArgumentError, "#{definition.key} storage constraint must stay separate from the UI range" unless definition.storage_constraint.nil?
      end
    end

    def type_list?(value)
      value.is_a?(Array) && value.any? && value.all? { |item| TYPE_NAMES.include?(item) }
    end
  end
end
