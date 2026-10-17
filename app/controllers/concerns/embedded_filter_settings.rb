# frozen_string_literal: true

# Opt in only from explicitly supported settings controllers. Never include globally.
module EmbeddedFilterSettings
  extend ActiveSupport::Concern

  included do
    layout :filter_settings_layout
    helper_method :embedded_filter_settings?, :embedded_filter_options, :embedded_settings_screen, :embedded_settings_home, :embedded_settings_title
    after_action :allow_embedded_filter_settings
  end

  private

  def embedded_settings_screen
    case controller_path
    when 'settings/user_posting_contexts', 'settings/user_posting_context_assignments'
      'postingStyles'
    else
      'filters'
    end
  end

  def embedded_settings_home
    embedded_settings_screen == 'postingStyles' ? settings_user_posting_contexts_path(embedded_filter_options) : filters_path(embedded_filter_options)
  end

  def embedded_settings_title
    embedded_settings_screen == 'postingStyles' ? I18n.t('user_posting_contexts.title') : I18n.t('filters.index.title')
  end

  def embedded_filter_settings?
    params[:embedded] == '1' && request.format.html?
  end

  def embedded_filter_options
    embedded_filter_settings? ? { embedded: '1' } : {}
  end

  def filter_settings_layout
    embedded_filter_settings? ? 'embedded_settings' : 'admin'
  end

  def allow_embedded_filter_settings
    # Redirects (including expired sessions), errors and non-HTML responses
    # retain the application's frame-ancestors 'none' policy.
    return unless embedded_filter_settings? && current_user&.functional? && response.status == 200 && response.media_type == 'text/html'

    return if embedded_settings_screen == 'postingStyles' && !current_user.can?(:administrator)

    policy = request.content_security_policy.clone
    policy.frame_ancestors :self
    request.content_security_policy = policy
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
  end
end
