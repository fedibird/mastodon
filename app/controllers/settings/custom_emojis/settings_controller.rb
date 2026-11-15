# frozen_string_literal: true

class Settings::CustomEmojis::SettingsController < Settings::PreferencesController
  private

  def after_update_redirect_path
    settings_custom_emojis_settings_path
  end
end
