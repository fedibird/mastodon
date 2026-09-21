# frozen_string_literal: true

# Admin form for the existing `action_review_policies` hash setting.
#
# Displayed values are effective modes from PolicySettings, not raw stored
# strings, so a leftover unsupported threshold still shows as `always`.
# Persistence keeps unknown extra keys when the stored blob is a hash.
class Form::ActionReviewSettings
  include ActiveModel::Model

  OPERATIONS = ActionReview::OperationRegistry.keys.freeze

  attr_accessor(*OPERATIONS.map(&:to_sym))

  validate :modes_must_be_supported

  def initialize(attributes = {})
    apply_current_policies
    super(attributes)
  end

  def save
    return false unless valid?

    persist_policies(merged_policies)
    true
  end

  private

  def apply_current_policies
    OPERATIONS.each do |key|
      public_send("#{key}=", ActionReview::PolicySettings.mode_for(key))
    end
  end

  def current_policies
    raw = Setting['action_review_policies']
    raw.is_a?(Hash) ? raw.stringify_keys : {}
  rescue StandardError
    {}
  end

  def merged_policies
    policies = current_policies
    OPERATIONS.each do |key|
      policies[key] = public_send(key).to_s.strip.downcase
    end
    policies
  end

  def persist_policies(hash)
    setting = Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies')
    setting.update(value: hash)
  end

  def modes_must_be_supported
    OPERATIONS.each do |key|
      mode = public_send(key).to_s.strip.downcase
      next if ActionReview::OperationRegistry.supported_policy_modes(key).include?(mode)

      errors.add(key.to_sym, I18n.t('admin.action_review_settings.errors.unsupported_mode'))
    end
  end
end
