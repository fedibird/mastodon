# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Hands one wrapper's Announce to ActivityPub distribution, once, and only
    # after the reference note's Create has been distributed.
    #
    # Contract
    # - Create first. While the mapping's published_at is null this does
    #   nothing and keeps the row active. The publish worker pushes the pending
    #   boosts of the mapping right after it writes published_at.
    # - Fail closed. The flag, the current policy, the projection, the mapping,
    #   and the reference note are read again here. If any no longer holds, the
    #   row is closed and the wrapper is discarded without an Announce. A job
    #   that was queued before an Undo, a scope change, a revoke, a purge, or
    #   an edit therefore cannot bring the share back.
    # - One job per generation. The row is locked FOR UPDATE and
    #   announced_at is the durable mark, so a second job or a Sidekiq retry
    #   is a no-op. Distribution is pushed before the mark is written, so a
    #   crash between them repeats the same Announce activity at worst.
    # - Local timelines are not touched. Only ActivityPub::DistributionWorker
    #   is enqueued. DistributionWorker is not, so the reference note's own
    #   Create fan-out is the only local appearance of the share.
    class BoostAnnounce
      def self.call(boost_id)
        new(boost_id).call
      end

      def initialize(boost_id)
        @boost_id = boost_id
      end

      def call
        removals = []
        outcome = ApplicationRecord.transaction do
          boost = ExternalProjectionLinkBoost.lock('FOR UPDATE').find_by(id: @boost_id)
          next :gone if boost.nil?
          next :ended unless boost.active?
          next :announced if boost.announced_at.present?

          decide(boost, removals)
        end
        Retire.enqueue_removals(removals)
        outcome
      end

      private

      def decide(boost, removals)
        mapping = ExternalProjectionLinkReference.find_by(id: boost.link_reference_id)
        reason = closing_reason(boost, mapping)
        if reason
          id = Retire.end!(boost, reason: reason)
          removals << id if id
          return :closed
        end

        return :waiting if mapping.published_at.nil?

        ActivityPub::DistributionWorker.perform_async(boost.wrapper_status_id)
        boost.update!(announced_at: Time.current)
        :announced
      end

      def closing_reason(boost, mapping)
        wrapper = Status.find_by(id: boost.wrapper_status_id)
        return 'wrapper_removed' if wrapper.nil?
        return 'projection_gone' unless marker_holds?(boost)
        return 'reference_unavailable' unless mapping_holds?(boost, mapping)
        return 'consent_withdrawn' unless consent_holds?(boost)

        begin
          ReferenceIntegrity.verify!(mapping, mapping.reference_status)
        rescue Error
          return 'reference_modified'
        end

        nil
      end

      def marker_holds?(boost)
        return false if boost.external_status_projection_id.nil?

        ExternalStatusProjection.exists?(id: boost.external_status_projection_id, user_id: boost.user_id, status_id: boost.projection_status_id)
      end

      def mapping_holds?(boost, mapping)
        mapping.present? &&
          mapping.active? &&
          mapping.user_id == boost.user_id &&
          mapping.reference_status_id.present? &&
          mapping.reference_status_id == boost.reference_status_id
      end

      def consent_holds?(boost)
        user = User.find_by(id: boost.user_id)
        return false if user.nil? || !Feature.permitted?(user) || !user.functional?

        policy = ExternalLinkSharePolicy.find_by(user_id: boost.user_id)
        policy.present? && policy.enabled? && policy.consented_at.present? && policy.visibility == boost.visibility
      end
    end
  end
end
