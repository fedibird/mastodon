# frozen_string_literal: true

# Opt in only from the two filter HTML controllers. Never include globally.
module EmbeddedFilterSettings
  extend ActiveSupport::Concern

  included do
    layout :filter_settings_layout
    helper_method :embedded_filter_settings?, :embedded_filter_options
    after_action :allow_embedded_filter_settings
  end

  private

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

    policy = request.content_security_policy.clone
    policy.frame_ancestors :self
    request.content_security_policy = policy
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
  end
end
