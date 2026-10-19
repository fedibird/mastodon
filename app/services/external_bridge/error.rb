# frozen_string_literal: true

module ExternalBridge
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code.to_s
      super(@code)
    end

    def http_status
      case code
      when 'feature_disabled', 'user_not_functional'
        403
      when 'not_found'
        404
      else
        422
      end
    end
  end
end
