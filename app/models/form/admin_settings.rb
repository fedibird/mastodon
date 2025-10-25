# frozen_string_literal: true

class Form::AdminSettings
  include ActiveModel::Model

  KEYS = %i(
    site_contact_username
    site_contact_email
    site_title
    site_short_description
    site_description
    site_extended_description
    site_terms
    registrations_mode
    closed_registrations_message
    open_deletion
    timeline_preview
    show_staff_badge
    show_moderator_badge
    bootstrap_timeline_accounts
    theme
    min_invite_role
    activity_api_enabled
    peers_api_enabled
    show_known_fediverse_at_about_page
    show_only_media_at_about_page
    show_without_media_at_about_page
    show_without_bot_at_about_page
    preview_sensitive_media
    custom_css
    profile_directory
    server_directory
    thumbnail
    mascot
    trends
    trendable_by_default
    show_domain_blocks
    show_domain_blocks_rationale
    noindex
    require_invite_text
    allow_poll_image
    poll_max_options
    reaction_max_per_account
    attachments_max
    pins_max
    reject_pattern
    reject_blurhash
  ).freeze

  BOOLEAN_KEYS = %i(
    open_deletion
    timeline_preview
    show_staff_badge
    show_moderator_badge
    activity_api_enabled
    peers_api_enabled
    show_known_fediverse_at_about_page
    show_only_media_at_about_page
    show_without_media_at_about_page
    show_without_bot_at_about_page
    preview_sensitive_media
    profile_directory
    server_directory
    trends
    trendable_by_default
    noindex
    require_invite_text
    allow_poll_image
  ).freeze

  INTEGER_KEYS = %i(
    poll_max_options
    reaction_max_per_account
    attachments_max
    pins_max
  ).freeze

  UPLOAD_KEYS = %i(
    thumbnail
    mascot
  ).freeze

  attr_accessor(*KEYS)

  validates :site_short_description, :site_description, html: { wrap_with: :p }
  validates :site_extended_description, :site_terms, :closed_registrations_message, html: true
  validates :registrations_mode, inclusion: { in: %w(open approved none) }
  validates :min_invite_role, inclusion: { in: %w(disabled user moderator admin) }
  validates :site_contact_email, :site_contact_username, presence: true
  validates :site_contact_username, existing_username: true
  validates :bootstrap_timeline_accounts, existing_username: { multiple: true }
  validates :show_domain_blocks, inclusion: { in: %w(disabled users all) }
  validates :show_domain_blocks_rationale, inclusion: { in: %w(disabled users all) }
  validates :poll_max_options, numericality: { greater_than: 2, less_than_or_equal_to: PollOptionsValidator::MAX_OPTIONS_LIMIT }
  validates :reaction_max_per_account, numericality: { greater_than_or_equal: 1, less_than_or_equal_to: EmojiReactionValidator::MAX_PER_ACCOUNT_LIMIT }
  validates :attachments_max, numericality: { greater_than_or_equal: 1, less_than_or_equal_to: MediaAttachment::ATTACHMENTS_LIMIT }
  validates :pins_max, numericality: { greater_than_or_equal: 1, less_than_or_equal_to: StatusPinValidator::LIMIT }
  validates :reject_pattern, regexp_syntax: true

  def initialize(_attributes = {})
    super
    initialize_attributes
  end

  def save
    return false unless valid?

    KEYS.each do |key|
      value = instance_variable_get("@#{key}")

      if UPLOAD_KEYS.include?(key) && !value.nil?
        upload = SiteUpload.where(var: key).first_or_initialize(var: key)
        upload.update(file: value)
      else
        setting = Setting.where(var: key).first_or_initialize(var: key)
        setting.update(value: typecast_value(key, value))
      end
    end
  end

  private

  def initialize_attributes
    KEYS.each do |key|
      instance_variable_set("@#{key}", Setting.public_send(key)) if instance_variable_get("@#{key}").nil?
    end
  end

  def typecast_value(key, value)
    if BOOLEAN_KEYS.include?(key)
      value == '1'
    elsif INTEGER_KEYS.include?(key)
      Integer(value)
    else
      value
    end
  end
end
