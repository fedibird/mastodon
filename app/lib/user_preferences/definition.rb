# frozen_string_literal: true

# Static description of one preference. It does not read a user or the audit catalog.
class UserPreferences::Definition
  ATTRIBUTE_NAMES = %i(
    key
    category
    owner
    storage_key
    derived
    configured_type
    effective_type
    public_type
    allowed_values_source
    ui_range
    default_source
    dependencies
    read_policy
    write_policy
    apply_hint
    legacy_formats
    source_refs
    api_key_candidate
    storage_constraint
  ).freeze

  def initialize(allowed_values: nil, allowed_values_resolver: nil, **attrs)
    ATTRIBUTE_NAMES.each do |name|
      next if name == :allowed_values_source && !attrs.key?(name)

      instance_variable_set(:"@#{name}", freeze_copy(attrs.fetch(name)))
    end
    @allowed_values = freeze_copy(allowed_values)
    @allowed_values_resolver = allowed_values_resolver
    freeze
  end

  attr_reader :key, :category, :owner, :storage_key, :derived,
              :configured_type, :effective_type, :public_type,
              :allowed_values_source, :ui_range, :default_source, :dependencies,
              :read_policy, :write_policy, :apply_hint, :legacy_formats, :source_refs,
              :api_key_candidate, :storage_constraint

  def allowed_values
    raw = @allowed_values_resolver ? @allowed_values_resolver.call : @allowed_values
    return nil if raw.nil?

    raw.map { |item| item.is_a?(String) ? item.dup.freeze : item }.freeze
  end

  def choice?(value)
    return nil if allowed_values.nil?

    allowed_values.include?(value)
  end

  def check(reader_value)
    unless reader_value.key.to_s == key
      raise ArgumentError, 'value key does not match definition'
    end

    UserPreferences::Conformance.new(self, reader_value)
  end

  def self.build_registry
    entries.to_h { |definition| [definition.key, definition] }
  end

  def self.entries
    [
      privacy,
      sensitive,
      language,
      translation_bar,
      translation_mode,
      features_policy,
      content_font,
      info_font,
      motion,
      preferred_language,
    ]
  end

  def self.privacy
    new(
      key: 'default_privacy',
      category: :posting,
      owner: :user,
      storage_key: 'default_privacy',
      derived: false,
      configured_type: [:nil, :string],
      effective_type: [:string],
      public_type: [:string],
      allowed_values_resolver: -> { Status.selectable_visibilities },
      allowed_values_source: 'Status.selectable_visibilities',
      ui_range: nil,
      default_source: 'no settings.yml key; User#setting_default_privacy uses the stored value, or private when account.locked, otherwise public',
      dependencies: ['account.locked'],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :reinitialize,
      legacy_formats: [],
      source_refs: ['app/models/user.rb', 'app/models/status.rb', 'app/lib/user_preferences/reader.rb'],
      api_key_candidate: 'user.default_privacy',
      storage_constraint: nil
    )
  end

  def self.sensitive
    boolean(
      key: 'default_sensitive',
      category: :posting,
      default_source: 'config/settings.yml default_sensitive false when no settings row exists',
      source_refs: ['config/settings.yml', 'app/lib/user_preferences/reader.rb'],
      apply_hint: :reinitialize
    )
  end

  def self.language
    new(
      key: 'default_language',
      category: :posting,
      owner: :user,
      storage_key: 'default_language',
      derived: false,
      configured_type: [:nil, :string],
      effective_type: [:nil, :string],
      public_type: [:nil, :string],
      allowed_values: nil,
      allowed_values_source: 'not a fixed enum; LanguagesHelper::SUPPORTED_LOCALES, nil, and regional tags stored as submitted',
      ui_range: nil,
      default_source: 'no settings.yml key; a missing or nil row stays nil on the raw getter',
      dependencies: [],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :reinitialize,
      legacy_formats: [],
      source_refs: ['app/models/user.rb', 'app/helpers/languages_helper.rb', 'app/lib/user_preferences/reader.rb'],
      api_key_candidate: 'user.default_language',
      storage_constraint: nil
    )
  end

  def self.preferred_language
    new(
      key: 'preferred_posting_language',
      category: :posting,
      owner: :user,
      storage_key: nil,
      derived: true,
      configured_type: nil,
      effective_type: [:nil, :string],
      public_type: [:nil, :string],
      allowed_values: nil,
      allowed_values_source: 'derived by User#valid_locale_cascade; not a stored enum',
      ui_range: nil,
      default_source: 'valid_locale_cascade(default_language, user.locale, request locale)',
      dependencies: ['default_language', 'user.locale', 'request_locale'],
      read_policy: :general,
      write_policy: :read_only,
      apply_hint: :reinitialize,
      legacy_formats: [],
      source_refs: ['app/models/user.rb', 'app/helpers/languages_helper.rb', 'app/lib/user_preferences/reader.rb'],
      api_key_candidate: 'user.preferred_posting_language',
      storage_constraint: nil
    )
  end

  def self.translation_bar
    new(
      key: 'show_translation_bar',
      category: :translation,
      owner: :user,
      storage_key: 'show_translation_bar',
      derived: false,
      configured_type: [:nil, :boolean, :string],
      effective_type: [:string],
      public_type: [:string],
      allowed_values: TranslationPreferences::VISIBILITIES,
      allowed_values_source: 'TranslationPreferences::VISIBILITIES',
      ui_range: nil,
      default_source: 'TranslationPreferences.normalize_visibility; nil, unknown strings, and a missing row follow new_features_policy and are not written back',
      dependencies: ['new_features_policy'],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :reinitialize,
      legacy_formats: [nil, true, false],
      source_refs: ['app/lib/translation_preferences.rb', 'app/models/user.rb', 'app/lib/user_preferences/reader.rb'],
      api_key_candidate: 'user.show_translation_bar',
      storage_constraint: nil
    )
  end

  def self.translation_mode
    new(
      key: 'translation_preferred_mode',
      category: :translation,
      owner: :user,
      storage_key: 'translation_preferred_mode',
      derived: false,
      configured_type: [:nil, :string],
      effective_type: [:string],
      public_type: [:string],
      allowed_values: TranslationPreferences::PREFERRED_MODES,
      allowed_values_source: 'TranslationPreferences::PREFERRED_MODES',
      ui_range: nil,
      default_source: 'config/settings.yml translated; TranslationPreferences.normalize_preferred_mode maps unknown values to translated on read',
      dependencies: [],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :reinitialize,
      legacy_formats: [],
      source_refs: ['app/lib/translation_preferences.rb', 'config/settings.yml', 'app/lib/user_preferences/reader.rb'],
      api_key_candidate: 'user.translation_preferred_mode',
      storage_constraint: nil
    )
  end

  def self.features_policy
    new(
      key: 'new_features_policy',
      category: :translation,
      owner: :user,
      storage_key: 'new_features_policy',
      derived: false,
      configured_type: [:nil, :string],
      effective_type: [:nil, :string],
      public_type: [:string],
      allowed_values: %w(conservative default tester),
      allowed_values_source: 'settings form radios and TranslationPreferences.default_visibility',
      ui_range: nil,
      default_source: 'config/settings.yml new_features_policy default when no settings row exists',
      dependencies: [],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :reinitialize,
      legacy_formats: [],
      source_refs: ['config/settings.yml', 'app/lib/translation_preferences.rb', 'app/views/settings/preferences/other/show.html.haml'],
      api_key_candidate: 'user.new_features_policy',
      storage_constraint: nil
    )
  end

  def self.content_font
    font('content_font_size', 'config/settings.yml content_font_size 15')
  end

  def self.info_font
    font('info_font_size', 'config/settings.yml info_font_size 15')
  end

  def self.motion
    boolean(
      key: 'reduce_motion',
      category: :appearance,
      default_source: 'config/settings.yml reduce_motion false when no settings row exists',
      source_refs: ['config/settings.yml', 'app/helpers/application_helper.rb', 'app/javascript/mastodon/initial_state.js', 'app/javascript/mastodon/utils/appearance_preferences.js'],
      apply_hint: :live
    )
  end

  def self.font(key, default_source)
    new(
      key: key,
      category: :appearance,
      owner: :user,
      storage_key: key,
      derived: false,
      configured_type: [:nil, :integer, :string],
      effective_type: [:nil, :integer, :string],
      public_type: [:integer],
      allowed_values: nil,
      allowed_values_source: nil,
      ui_range: { min: 10, max: 20, step: nil },
      default_source: default_source,
      dependencies: [],
      read_policy: :general,
      write_policy: :general,
      apply_hint: :live,
      legacy_formats: [:numeric_string],
      source_refs: ['config/settings.yml', 'app/views/settings/preferences/appearance/show.html.haml', 'app/lib/user_preferences/reader.rb', 'app/javascript/mastodon/utils/appearance_preferences.js'],
      api_key_candidate: "user.#{key}",
      storage_constraint: nil
    )
  end

  def self.boolean(key:, category:, default_source:, source_refs:, apply_hint:)
    new(
      key: key,
      category: category,
      owner: :user,
      storage_key: key,
      derived: false,
      configured_type: [:nil, :boolean],
      effective_type: [:nil, :boolean],
      public_type: [:boolean],
      allowed_values: nil,
      allowed_values_source: nil,
      ui_range: nil,
      default_source: default_source,
      dependencies: [],
      read_policy: :general,
      write_policy: :general,
      apply_hint: apply_hint,
      legacy_formats: [],
      source_refs: source_refs,
      api_key_candidate: "user.#{key}",
      storage_constraint: nil
    )
  end

  private

  def freeze_copy(value)
    case value
    when nil then nil
    when Array then value.map { |item| item.is_a?(String) ? item.dup.freeze : item }.freeze
    when Hash then value.dup.freeze
    when String then value.dup.freeze
    else value
    end
  end

end
