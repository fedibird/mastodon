# frozen_string_literal: true

module EmbeddedPostingStyleSettings
  extend ActiveSupport::Concern
  include EmbeddedRailsSettings

  private

  def embedded_settings_authorized?
    super && current_user.can?(:administrator)
  end

  def embedded_settings_screen
    'postingStyles'
  end

  def embedded_settings_home
    settings_user_posting_contexts_path(embedded_settings_options)
  end

  def embedded_settings_title
    I18n.t('user_posting_contexts.title')
  end
end
