# frozen_string_literal: true

# Correlates an inbound Accept/Reject of a local follow request back to the
# follow-import target that originated it, using the durable follow_request_uri
# stored on the target (the FollowRequest DB row is ephemeral — authorize!/
# reject! destroys it — but its ActivityPub URI is stable).
#
# Records execution-state bookkeeping only. It never applies friction, never
# writes to the moderation ledger, and is failure-tolerant: correlation must
# never break inbound Accept/Reject handling.
module FollowImport
  class TargetResponseCorrelator
    class << self
      def accepted(follow_request)
        correlate(follow_request, :mark_accepted)
      end

      def rejected(follow_request)
        correlate(follow_request, :mark_rejected)
      end

      private

      def correlate(follow_request, transition)
        uri = follow_request&.uri
        return if uri.blank?

        target = FollowImportTarget.find_by(follow_request_uri: uri)
        return if target.nil?

        FollowImport::TargetTransitionService.new.public_send(transition, target)
      rescue StandardError => e
        Rails.logger.warn("[FollowImport::TargetResponseCorrelator] #{transition} failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
