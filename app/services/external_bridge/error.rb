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
      when 'feature_disabled', 'tester_only', 'user_not_functional', 'feed_routes_disabled', 'consent_required', 'not_owner'
        403
      when 'not_found'
        404
      when 'stale_feed_routes', 'reference_conflict', 'policy_changed', 'canonical_url_changed', 'share_outdated'
        409
      else
        422
      end
    end
  end
end
