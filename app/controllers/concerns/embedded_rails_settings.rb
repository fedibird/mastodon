# frozen_string_literal: true

# Opt in only from the explicitly listed settings controllers, never globally.
module EmbeddedRailsSettings
  extend ActiveSupport::Concern

  included do
    layout :embedded_settings_layout
    helper_method :embedded_settings_screen, :embedded_settings_home, :embedded_settings_title, :embedded_settings_options
    after_action :allow_embedded_settings
  end

  private

  def embedded_settings?
    params[:embedded] == '1' && request.format.html? && embedded_settings_authorized?
  end

  def embedded_settings_authorized?
    current_user&.functional?
  end

  def embedded_settings_options
    embedded_settings? ? { embedded: '1' } : {}
  end

  def embedded_settings_layout
    embedded_settings? ? 'embedded_settings' : 'admin'
  end

  def allow_embedded_settings
    # Redirects, errors (including 409), login and JSON previews keep DENY/none.
    # Validation/conflict main is inserted by the parent into its protected head.
    return unless embedded_settings? && response.status == 200 && response.media_type == 'text/html'

    policy = request.content_security_policy.clone
    policy.frame_ancestors :self
    request.content_security_policy = policy
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
  end
end
