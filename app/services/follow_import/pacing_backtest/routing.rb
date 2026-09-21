# frozen_string_literal: true

# Destination/origin routing aligned with PR F/G RemoteAdmission.
# Local destinations consume no remote dest/origin caps. Missing
# destination uses the synthetic unknown bucket and is never unlimited.
module FollowImport
  class PacingBacktest
    module Routing
      UNKNOWN_DESTINATION = FollowImport::RemoteAdmission::UNKNOWN_DESTINATION

      module_function

      def local_destination?(domain)
        return false if domain.blank?

        TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
      rescue StandardError
        false
      end

      def destination_pressure_key(domain)
        return if local_destination?(domain)

        domain.to_s.presence || UNKNOWN_DESTINATION
      end

      def origin_pressure_key(domain, origin)
        return if local_destination?(domain)

        origin.to_s.presence
      end

      def persist_destination?(domain)
        domain.present? && !local_destination?(domain)
      end

      def persist_origin?(domain, origin)
        origin.present? && !local_destination?(domain)
      end
    end
  end
end
