# frozen_string_literal: true

# == Schema Information
#
# Table name: user_posting_contexts
#
#  id                :bigint(8)        not null, primary key
#  user_id           :bigint(8)        not null
#  name              :string(80)       not null
#  icon              :string(64)
#  purpose           :text
#  target_kind       :string(16)       default("none"), not null
#  target_account_id :bigint(8)
#  target_hashtag    :string(100)
#  defaults          :jsonb            not null
#  managed           :jsonb            not null
#  position          :integer          default(0), not null
#  enabled           :boolean          default(TRUE), not null
#  schema_version    :integer          default(1), not null
#  lock_version      :integer          default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# A user's saved posting style. Ownership is the User, not the Account, so a
# later account move does not have to relocate these rows.
#
# schema_version 1 keeps inheritance, explicit values, and explicit clears
# distinct. See UserPostingContext::Defaults. The composer reads
# composer_api_payload and does not write this table. UserPostingContext::Preview
# remains the settings-page merge and does not run Discovery for the index.
class UserPostingContext < ApplicationRecord
  ADVISORY_HASHTAG_RULE_ID = 'user-posting-context'
  # The hashtag named as the destination is not stored in `managed`. A later
  # composer can recognize it by this rule id and origin. See Preview.
  DESTINATION_HASHTAG_RULE_ID = 'user-posting-context:destination'
  HASHTAG_ORIGIN_STYLE = 'style'
  HASHTAG_ORIGIN_DESTINATION = 'destination'
  HASHTAG_ORIGIN_DISCOVERY = 'discovery'
  MAX_PER_USER = 50
  SCHEMA_VERSION = 1
  TARGET_KINDS = %w(none hashtag group).freeze
  ASSIGNABLE = %w(
    name icon purpose target_kind target_account_id target_hashtag lock_version
    visibility_choice visibility_value language_choice language_code
    sensitive_choice sensitive_value spoiler_choice spoiler_text hashtags_text
  ).freeze
  CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/.freeze
  PURPOSE_CONTROL_CHARACTERS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.freeze

  belongs_to :user, inverse_of: :user_posting_contexts
  belongs_to :target_account, class_name: 'Account', optional: true, inverse_of: false

  # External input cannot retarget a row or rewrite the storage version.
  attr_readonly :user_id, :schema_version

  attribute :visibility_choice, :string
  attribute :visibility_value, :string
  attribute :language_choice, :string
  attribute :language_code, :string
  attribute :sensitive_choice, :string
  attribute :sensitive_value, :string
  attribute :spoiler_choice, :string
  attribute :spoiler_text, :string
  attribute :hashtags_text, :string
  attribute :submission, :boolean, default: false

  validates :name, presence: true, length: { maximum: 80 }
  validates :purpose, length: { maximum: 500 }, allow_nil: true
  validates :icon, length: { maximum: 64 }, allow_nil: true
  validates :target_kind, inclusion: { in: TARGET_KINDS }
  validates :schema_version, inclusion: { in: [SCHEMA_VERSION] }
  validate :text_is_plain
  validate :target_contract
  validate :stored_defaults_contract
  validate :stored_managed_contract
  validate :within_user_limit, on: :create

  before_validation :normalize_text
  before_validation :compile_submission, if: :submission?
  before_save :clear_inactive_target
  before_create :append_position

  scope :ordered, -> { order(:position, :id) }
  scope :enabled, -> { where(enabled: true) }

  # Duplicate names stay allowed. The suffix is only the default label.
  def self.copied_name(name)
    suffix = I18n.t('user_posting_contexts.copy_suffix')
    base = name.to_s
    return "#{base}#{suffix}" if base.length + suffix.length <= 80

    room = 80 - suffix.length
    room = 0 if room.negative?
    "#{base[0, room]}#{suffix}"
  end

  # Values a later composer can read without learning the form field names.
  # Missing defaults keys mean inherit. Do not treat a missing discovery
  # result as permission to post; ask UserPostingContext::Preview.
  def composer_overrides
    {
      'schema_version' => schema_version,
      'id' => id&.to_s,
      'name' => name,
      'icon' => icon,
      'enabled' => enabled,
      'target' => {
        'kind' => target_kind,
        'account_id' => target_account_id&.to_s,
        'hashtag' => target_hashtag,
      },
      'defaults' => defaults,
      'managed' => managed,
    }
  end

  # Read model for the composer. Label is display-only. Discovery is not called.
  def composer_api_payload
    payload = composer_overrides
    payload['purpose'] = purpose
    payload['revision'] = lock_version
    payload['target'] = payload['target'].merge('label' => target_label)
    payload
  end

  def apply_form(values)
    data = values.to_h.stringify_keys
    @submitted_keys = data.keys
    assign_attributes(data.slice(*ASSIGNABLE))
    self.submission = true
  end

  def submitted?(key)
    @submitted_keys.nil? || @submitted_keys.include?(key.to_s)
  end

  def fill_form_fields
    Defaults.form_fields(defaults).each { |key, value| public_send("#{key}=", value) }
    self.hashtags_text = ManagedHashtags.form_text(managed)
    self
  end

  private

  def target_label
    case target_kind
    when 'hashtag'
      target_hashtag.present? ? "##{target_hashtag}" : nil
    when 'group'
      target_account&.acct
    end
  end

  def normalize_text
    self.name = name.to_s.strip
    self.icon = icon.to_s.strip.presence
    self.purpose = purpose.to_s.strip.presence
    self.target_kind = 'none' if target_kind.blank?
  end

  def compile_submission
    Defaults.write(self)
    ManagedHashtags.write(self)
    normalize_target_hashtag if submitted?('target_hashtag') && target_kind == 'hashtag'
  end

  def normalize_target_hashtag
    pair = HashtagName.canonicalize(target_hashtag)
    self.target_hashtag = pair.first if pair
  end

  def clear_inactive_target
    case target_kind
    when 'none'
      self.target_account_id = nil
      self.target_hashtag = nil
    when 'hashtag'
      self.target_account_id = nil
      pair = HashtagName.canonicalize(target_hashtag)
      self.target_hashtag = pair.first if pair
    when 'group'
      self.target_hashtag = nil
    end
  end

  def append_position
    self.position = self.class.where(user_id: user_id).maximum(:position).to_i + 1
  end

  def text_is_plain
    errors.add(:base, I18n.t('user_posting_contexts.errors.name')) if name.to_s.match?(CONTROL_CHARACTERS)
    errors.add(:base, I18n.t('user_posting_contexts.errors.purpose')) if purpose.to_s.match?(PURPOSE_CONTROL_CHARACTERS)
    errors.add(:base, I18n.t('user_posting_contexts.errors.icon')) if icon.to_s.match?(CONTROL_CHARACTERS) || icon.to_s.match?(/[<>]/)
  end

  def target_contract
    case target_kind
    when 'hashtag'
      pair = HashtagName.canonicalize(target_hashtag)
      errors.add(:base, I18n.t('user_posting_contexts.errors.invalid_hashtag')) if pair.nil?
    when 'group'
      account = target_account
      if target_account_id.blank? || account.nil? || !account.group?
        errors.add(:base, I18n.t('user_posting_contexts.errors.group_invalid'))
      end
    end
  end

  def stored_defaults_contract
    Defaults.validate_stored(self)
  end

  def stored_managed_contract
    ManagedHashtags.validate_stored(self)
  end

  def within_user_limit
    return if user.nil?
    return if user.user_posting_contexts.count < MAX_PER_USER

    errors.add(:base, I18n.t('user_posting_contexts.errors.limit', count: MAX_PER_USER))
  end
end
