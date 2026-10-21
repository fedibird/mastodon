# frozen_string_literal: true

module ExternalBridge
  # external is an internal visibility. Callers that accept a visibility from
  # a person, a client, or a reblog option use reject_composable! so the value
  # cannot become a status or be ignored in favour of a public post.
  module Visibility
    NAME = 'external'
    VALUE = 201

    module_function

    def external_token?(value)
      return false if value.nil?

      normalized = value.to_s.strip
      normalized.casecmp(NAME).zero? || normalized == VALUE.to_s
    end

    def reject_composable!(value)
      return unless external_token?(value)

      raise Mastodon::ValidationError, I18n.t('external_bridge.errors.external_visibility_rejected')
    end
  end
end
