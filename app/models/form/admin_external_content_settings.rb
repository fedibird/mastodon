# frozen_string_literal: true

# Server settings for external article media. Not a user preference.
class Form::AdminExternalContentSettings
  include ActiveModel::Model

  KEYS = %i(external_bridge_rss_video_policy external_bridge_rss_video_max_download_mib).freeze

  attr_accessor(*KEYS)

  validates :external_bridge_rss_video_policy, inclusion: { in: ExternalBridge::RSS::Media::Policy::MODES }
  validate :download_limit_in_range

  def initialize(attributes = {})
    apply_current
    super(attributes)
  end

  def save
    return false unless valid?

    KEYS.each do |key|
      setting = Setting.where(var: key.to_s).first_or_initialize(var: key.to_s)
      setting.update!(value: cast(key))
    end
    true
  end

  private

  def apply_current
    self.external_bridge_rss_video_policy = ExternalBridge::RSS::Media::Policy.mode
    self.external_bridge_rss_video_max_download_mib = stored_mib
  end

  def stored_mib
    value = Setting.external_bridge_rss_video_max_download_mib.to_i
    return value if (1..ExternalBridge::RSS::Media::Policy.max_mib).cover?(value)

    ExternalBridge::RSS::Media::Policy::DEFAULT_MIB
  end

  def cast(key)
    return external_bridge_rss_video_policy.to_s if key == :external_bridge_rss_video_policy

    Integer(external_bridge_rss_video_max_download_mib, 10)
  end

  def download_limit_in_range
    number = Integer(external_bridge_rss_video_max_download_mib, 10)
    return if (1..ExternalBridge::RSS::Media::Policy.max_mib).cover?(number)

    errors.add(:external_bridge_rss_video_max_download_mib, :inclusion)
  rescue ArgumentError, TypeError
    errors.add(:external_bridge_rss_video_max_download_mib, :not_a_number)
  end
end
