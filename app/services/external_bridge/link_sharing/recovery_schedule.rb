# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # One mapping's place in the unpublished recovery scan.
    #
    # next_recovery_at NULL means this row has not been visited. Those rows
    # are selected first, so a stuck head cannot keep the scan on the same
    # ids. A time in the future means Sidekiq accepted a job. The row stays
    # out of the scan until that time, which is longer than four scheduler
    # passes. A time at or before now means the enqueue was refused or the
    # claim expired, and the row may be tried again.
    #
    # published_at and state still decide eligibility. This column does not.
    module RecoverySchedule
      CLAIM_FOR = 30.minutes

      def self.claim!(id)
        eligible(id).update_all(claim_assignment) == 1
      end

      # The job was not accepted. Leave the row eligible now, but visited,
      # so the next pass continues with rows that are still NULL.
      def self.visit_without_claim!(id)
        ExternalProjectionLinkReference.where(id: id, published_at: nil).update_all(
          'next_recovery_at = NOW(), updated_at = CURRENT_TIMESTAMP'
        )
      end

      def self.eligible(id)
        ExternalProjectionLinkReference
          .where(id: id, published_at: nil, state: %w(active superseded))
          .where.not(reference_status_id: nil)
          .where('next_recovery_at IS NULL OR next_recovery_at <= NOW()')
      end

      def self.claim_assignment
        "next_recovery_at = NOW() + make_interval(secs => #{CLAIM_FOR.to_i}), updated_at = CURRENT_TIMESTAMP"
      end
      private_class_method :eligible, :claim_assignment
    end
  end
end
