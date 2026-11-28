# frozen_string_literal: true

module WebUiDomains
  class Error < StandardError; end

  # Raised at boot when WEB_UI_DOMAINS contains anything other than empty
  # entries. The process stops so a partial list cannot be adopted.
  class ConfigurationError < Error; end
end
