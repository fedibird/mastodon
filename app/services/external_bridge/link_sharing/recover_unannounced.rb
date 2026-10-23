# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Outbox scan for boost rows whose Announce was never handed to
    # distribution: not yet decided, or decided (announced_at) with the
    # ActivityPub job not accepted (announce_enqueued_at null). Only rows whose reference Create is already distributed
    # (published_at set) are selected, so a row waiting for the Create is not
    # pushed on every pass; the publish worker pushes it when the Create is
    # done. The flag and the policy are not read here: the worker decides
    # whether the share is still permitted and closes it if not.
    class RecoverUnannounced
      BATCH = 20

      def self.call
        new.call
      end

      def call
        selected = ids
        selected.each { |id| BoostSchedule.enqueue!(id) }
        Retire.end_orphans!
        selected.size
      end

      private

      def ids
        ExternalProjectionLinkBoost
          .where(announce_enqueued_at: nil, state: 'active')
          .where.not(wrapper_status_id: nil)
          .where('external_projection_link_boosts.next_announce_at IS NULL OR external_projection_link_boosts.next_announce_at <= NOW()')
          .joins('INNER JOIN external_projection_link_references link_refs ON link_refs.id = external_projection_link_boosts.link_reference_id')
          .where.not(link_refs: { published_at: nil })
          .order(Arel.sql('external_projection_link_boosts.next_announce_at ASC NULLS FIRST, external_projection_link_boosts.id ASC'))
          .limit(BATCH)
          .pluck(:id)
      end
    end
  end
end
