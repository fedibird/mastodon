# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Ends active boost rows and takes their wrapper Statuses away. An announced
    # wrapper is discarded and then removed by LinkWrapperRemovalWorker (the E4
    # counterpart of the RemovalWorker that Api::V1::Statuses::ReblogsController
    # uses for an ordinary unreblog). The reference note and the projection are
    # not touched.
    #
    # Every method here expects the caller to hold the rows FOR UPDATE inside a
    # transaction and to hand the returned wrapper ids to enqueue_removals
    # after that transaction commits. Only a wrapper whose Announce was already
    # handed to distribution needs LinkWrapperRemovalWorker, which sends the Undo and
    # then removes the row. A wrapper that never left the server has no remote
    # copy and no timeline entry to take back, so it is removed here. Removing
    # it matters: Status validates one boost per Account and note, and that
    # check does not look at discarded rows, so a left-over row would block the
    # next share.
    module Retire
      module_function

      ORPHAN_BATCH = 20

      # @return [Integer, nil] wrapper id that needs LinkWrapperRemovalWorker
      def end!(boost, reason:)
        return nil unless boost.active?

        wrapper = Status.unscoped.find_by(id: boost.wrapper_status_id)
        remove_now = wrapper.present? && boost.announced_at.blank?

        # A wrapper that never left the server is deleted below. Its id is
        # cleared in this same UPDATE: the foreign key SET NULL that follows the
        # delete would otherwise update this row a second time in the same
        # transaction, and PostgreSQL then re-checks the row's key against the
        # mapping (FOR KEY SHARE). Boost holds the mapping before the boost
        # rows, so that second lock order is a deadlock with a concurrent boost.
        attributes = { state: 'undone', undone_at: Time.current, ended_reason: reason.to_s }
        attributes[:wrapper_status_id] = nil if remove_now
        boost.update!(attributes)
        BoostEvents.changed!(boost.user_id, boost.projection_status_id)
        return nil if wrapper.nil?

        if remove_now
          wrapper.destroy!
          return nil
        end
        return nil if wrapper.deleted_at.present?

        wrapper.discard
        wrapper.id
      end

      def end_for_projections!(status_ids, reason:)
        ids = Array(status_ids).compact
        return [] if ids.empty?

        ExternalProjectionLinkBoost.lock('FOR UPDATE')
                                   .where(projection_status_id: ids, state: 'active')
                                   .order(:id)
                                   .filter_map { |boost| end!(boost, reason: reason) }
      end

      def end_orphans!
        removals = []
        ApplicationRecord.transaction do
          ExternalProjectionLinkBoost.lock('FOR UPDATE SKIP LOCKED')
                                     .where(state: 'active', external_status_projection_id: nil)
                                     .order(:id)
                                     .limit(ORPHAN_BATCH)
                                     .each do |boost|
            id = end!(boost, reason: 'projection_gone')
            removals << id if id
          end
        end
        enqueue_removals(removals)
        removals.size
      end

      # The lease of LinkWrapperRemovalWorker for one wrapper. Every method is a
      # single conditional UPDATE on the boost row: no session state, no advisory
      # lock, no transaction that spans the work, so the exclusion holds behind
      # any connection pooler (PgBouncer in transaction pooling mode included).
      #
      # @return [Boolean] true when this token now holds the lease: the share is
      #   ended (`undone`), the removal is not acknowledged, and no live lease of
      #   another job exists
      def claim_removal!(wrapper_id, token, lease)
        ExternalProjectionLinkBoost
          .where(wrapper_status_id: wrapper_id, state: 'undone', removal_acknowledged_at: nil)
          .where('removal_lease_until IS NULL OR removal_lease_until <= NOW()')
          .update_all(['removal_lease_token = ?, removal_lease_until = NOW() + make_interval(secs => ?)', token, lease.to_i])
          .positive?
      end

      # The work is done: RemoveStatusService returned, so the Undo of an
      # announced share has been handed to ActivityPub delivery (delivery itself
      # retries in its own workers). Only the current lease holder records it. It
      # is a fact about the work, not about the row: Mastodon keeps a wrapper that
      # sits in an unresolved report (discarded, not destroyed), so the wrapper's
      # existence never says whether the work is done.
      #
      # Matched by token alone: RemoveStatusService may have destroyed the wrapper,
      # which nulls wrapper_status_id on the row (ON DELETE SET NULL), and the row
      # must still be closed out.
      def acknowledge_removal!(token)
        ExternalProjectionLinkBoost
          .where(state: 'undone', removal_lease_token: token)
          .update_all(removal_acknowledged_at: Time.current, removal_lease_until: nil, removal_lease_token: nil)
          .positive?
      end

      # The job failed: give the lease back so the next push does not wait for it
      # to expire. A job that dies without reaching this leaves the lease to expire.
      def release_removal!(token)
        ExternalProjectionLinkBoost
          .where(state: 'undone', removal_lease_token: token)
          .update_all(removal_lease_until: nil, removal_lease_token: nil)
      end

      def enqueue_removals(wrapper_ids)
        Array(wrapper_ids).compact.each { |id| LinkWrapperRemovalWorker.perform_async(id) }
      end
    end
  end
end
