# frozen_string_literal: true

class REST::PreferencesSerializer < ActiveModel::Serializer
  attribute :posting_default_privacy, key: 'posting:default:visibility'
  attribute :posting_default_sensitive, key: 'posting:default:sensitive'
  attribute :posting_default_language, key: 'posting:default:language'

  attribute :reading_default_sensitive_media, key: 'reading:expand:media'
  attribute :reading_default_sensitive_text, key: 'reading:expand:spoilers'
  attribute :reading_autoplay_gifs, key: 'reading:autoplay:gifs'

  def posting_default_privacy
    preference_effective('default_privacy')
  end

  def posting_default_sensitive
    preference_effective('default_sensitive')
  end

  def posting_default_language
    preference_effective('preferred_posting_language')
  end

  def reading_default_sensitive_media
    object.user.setting_display_media
  end

  def reading_default_sensitive_text
    object.user.setting_expand_spoilers
  end

  def reading_autoplay_gifs
    object.user.setting_auto_play_avatar &&
      object.user.setting_auto_play_emoji &&
      object.user.setting_auto_play_header &&
      object.user.setting_auto_play_media
  end

  private

  def preference_reader
    return @preference_reader if defined?(@preference_reader)

    @preference_reader = UserPreferences::Reader.new(object.user)
  end

  def preference_effective(key)
    preference_reader.get(key).effective
  end
end
