# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Owner-facing text for a feed failure. HTTP statuses stay distinct from
    # a transport failure, and the raw code is never shown.
    module ErrorMessage
      HTTP_STATUS = /\Ahttp_([1-5]\d\d)\z/

      module_function

      def for(code)
        text = code.to_s
        match = HTTP_STATUS.match(text)
        return I18n.t('external_bridge.errors.http_status', status: match[1]) if match

        I18n.t("external_bridge.errors.#{text}", default: I18n.t('external_bridge.errors.fetch_failed'))
      end
    end
  end
end
