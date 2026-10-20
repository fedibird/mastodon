# frozen_string_literal: true

module ExternalBridge
  module Guards
    module_function

    def reject_target!(status)
      return if status.nil?
      return unless ProjectionPrivacy.private_status?(status)

      raise Mastodon::ValidationError, I18n.t('external_bridge.errors.projection_not_target')
    end
  end
end
