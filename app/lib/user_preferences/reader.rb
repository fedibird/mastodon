# frozen_string_literal: true

# P1-1 reads the keys below. The audit catalog keeps every other setting.
# This class does not load that catalog and does not decide who may read it.
class UserPreferences::Reader
  STORAGE_KEYS = %w(
    default_privacy
    default_sensitive
    default_language
    show_translation_bar
    translation_preferred_mode
    new_features_policy
    content_font_size
    info_font_size
    reduce_motion
  ).freeze
  DERIVED_KEYS = %w(preferred_posting_language).freeze
  KEYS = (STORAGE_KEYS + DERIVED_KEYS).freeze
  NUMERIC_KEYS = %w(content_font_size info_font_size).freeze
  USE_LOCALE = Object.new.freeze

  def initialize(user, account: nil, locale: USE_LOCALE)
    @user = user
    validate_account!(account) unless account.nil?
    @account = account
    @locale = locale
  end

  def get(key)
    name = key.to_s
    raise UserPreferences::UnsupportedKey, name unless KEYS.include?(name)

    return derived_language if name == 'preferred_posting_language'

    state, configured = storage_for(name)
    effective = effective_for(name, state, configured)
    UserPreferences::Value.new(
      key: name,
      state: state,
      configured: configured,
      effective: effective,
      public_value: public_value_for(name, effective)
    )
  end

  def read
    KEYS.index_with { |key| get(key) }
  end

  private

  def validate_account!(account)
    return if account.id.present? && account.id == @user.account_id

    raise ArgumentError, 'account must be the account that belongs to the user'
  end

  def records
    return @records if defined?(@records)

    @records = Setting.unscoped.where(
      thing_type: @user.class.base_class.to_s,
      thing_id: @user.id,
      var: STORAGE_KEYS
    ).index_by(&:var)
  end

  def storage_for(key)
    record = records[key]
    return [:absent, nil] unless record

    value = record.value
    return [:nil, nil] if value.nil?

    [:present, value]
  end

  def effective_for(key, state, configured)
    case key
    when 'default_privacy'
      # Match User#setting_default_privacy. Only nil and false are blank to ||.
      # A stored "" stays "", because String is truthy.
      raw = state == :absent ? nil : configured
      raw || (account.locked? ? 'private' : 'public')
    when 'show_translation_bar'
      stored = state == :absent ? nil : configured
      TranslationPreferences.normalize_visibility(stored, effective_policy)
    when 'translation_preferred_mode'
      stored = state == :absent ? yaml_default(key) : configured
      TranslationPreferences.normalize_preferred_mode(stored)
    when 'default_language', 'default_sensitive', 'new_features_policy', 'content_font_size', 'info_font_size', 'reduce_motion'
      return yaml_default(key) if state == :absent

      configured
    end
  end

  def effective_policy
    state, configured = storage_for('new_features_policy')
    state == :absent ? yaml_default('new_features_policy') : configured
  end

  def derived_language
    state, configured = storage_for('default_language')
    raw = state == :absent ? nil : configured
    language = @user.valid_locale_cascade(raw, @user.locale, fallback_locale)
    UserPreferences::Value.new(
      key: 'preferred_posting_language',
      state: :derived,
      configured: nil,
      effective: language,
      public_value: language
    )
  end

  def public_value_for(key, effective)
    return coerce_integer(effective) if NUMERIC_KEYS.include?(key)

    effective
  end

  def coerce_integer(value)
    return value if value.is_a?(Integer)
    return Integer(value, 10) if value.is_a?(String) && value.match?(/\A-?\d+\z/)

    value
  end

  def yaml_default(key)
    defaults = Setting.default_settings
    defaults[key] if defaults
  end

  def account
    @account || @user.account
  end

  def fallback_locale
    return I18n.locale if @locale.equal?(USE_LOCALE)

    @locale
  end
end
