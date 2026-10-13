# frozen_string_literal: true

# One stored preference key per call, for the Rails form and Credentials
# inputs that public Writer#apply rejects. Controllers do not call this yet.
# Each call uses Writer's lock, revision, ChangeSet, and after-commit hooks.
class UserPreferences::LegacyWriter
  KEYS = UserPreferences::WriteContract::KEYS
  BOOLEAN_KEYS = %w(default_sensitive reduce_motion).freeze
  SKIP = Object.new
  UNSET_POLICY = Object.new
  private_constant :SKIP, :UNSET_POLICY

  def initialize(user, policy: UNSET_POLICY)
    @user = user
    @writer = UserPreferences::Writer.new(user)
    # Omitted policy is snapshotted once. An explicit nil stays nil.
    @policy = policy.equal?(UNSET_POLICY) ? user.setting_new_features_policy : policy
    @boolean = ActiveModel::Type::Boolean.new
  end

  def update(key, value)
    @writer.send(:refuse_open_transaction!)
    stored = prepare(key, value)
    return @writer.send(:empty_result) if stored.equal?(SKIP)

    @writer.send(:commit_checked, key, stored)
  end

  private

  def prepare(key, value)
    name = string_key(key)
    raise invalid(name, 'unknown_key') unless KEYS.include?(name)
    raise invalid(name, 'invalid_type') if non_scalar?(value)
    return SKIP if value.nil?

    case name
    when *BOOLEAN_KEYS
      cast_boolean(name, value)
    when 'show_translation_bar'
      normalize_bar(name, value)
    when 'translation_preferred_mode'
      normalize_mode(name, value)
    else
      raise invalid(name, 'invalid_type') unless value.is_a?(String)

      value
    end
  end

  def cast_boolean(key, value)
    raise invalid(key, 'invalid_type') unless value.is_a?(String) || value == true || value == false || value.is_a?(Integer)

    @boolean.cast(value)
  end

  def normalize_bar(key, value)
    raise invalid(key, 'invalid_type') unless value.is_a?(String) || value == true || value == false

    TranslationPreferences.normalize_visibility(value, bar_policy)
  end

  def normalize_mode(key, value)
    raise invalid(key, 'invalid_type') unless value.is_a?(String)

    TranslationPreferences.normalize_preferred_mode(value)
  end

  def bar_policy
    @policy
  end

  def string_key(key)
    return key if key.is_a?(String)

    raise invalid(nil, 'invalid_key')
  end

  def non_scalar?(value)
    value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(ActionController::Parameters)
  end

  def invalid(key, code)
    UserPreferences::InvalidInput.new([{ 'key' => key, 'code' => code }])
  end
end
