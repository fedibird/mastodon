# frozen_string_literal: true

# Destination/origin routing aligned with PR F/G RemoteAdmission.
# Locality comes from Attempt#destination_is_local when the loader (or
# fixture) supplied an explicit observation. Raw in-memory attempts with
# a nil hint still fall back to TagManager. Anonymous identities must
# never be parsed as host names.
#
# Local destinations consume no remote dest/origin caps. Missing
# destination uses the synthetic unknown bucket for destination
# pressure only; origin pressure is not applied because production
# cannot look up a destination→origin mapping without a dest key.
# Observed origin may still persist adaptive controller state after
# an actual HTTP delivery.
module FollowImport
  class PacingBacktest
    module Routing
      UNKNOWN_DESTINATION = FollowImport::RemoteAdmission::UNKNOWN_DESTINATION

      module_function

      def local_destination?(attempt)
        return false if attempt.destination_domain.blank?
        return true if attempt.destination_is_local == true
        return false if attempt.destination_is_local == false

        tag_manager_local?(attempt.destination_domain)
      end

      def destination_pressure_key(attempt)
        return if local_destination?(attempt)

        attempt.destination_domain.to_s.presence || UNKNOWN_DESTINATION
      end

      def origin_pressure_key(attempt)
        return if attempt.destination_domain.blank? || local_destination?(attempt)

        attempt.endpoint_origin.to_s.presence
      end

      def persist_destination?(attempt)
        attempt.destination_domain.present? && !local_destination?(attempt)
      end

      def persist_origin?(attempt)
        attempt.endpoint_origin.present? && !local_destination?(attempt)
      end

      def tag_manager_local?(domain)
        TagManager.instance.local_domain?(domain) || TagManager.instance.web_domain?(domain)
      rescue StandardError
        false
      end
    end
  end
end
