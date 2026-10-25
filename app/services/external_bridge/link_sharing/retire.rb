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

      # LinkWrapperRemovalWorker finished for this wrapper: RemoveStatusService returned,
      # so the Undo of an announced share has been handed to ActivityPub
      # delivery (delivery itself retries in its own workers). It is a fact about
      # the work, not about the row: Mastodon keeps a wrapper that sits in an
      # unresolved report (discarded, not destroyed), so the wrapper's existence
      # never says whether the work is done.
      def acknowledge_removal!(wrapper_id)
        ExternalProjectionLinkBoost.where(wrapper_status_id: wrapper_id, state: 'undone', removal_acknowledged_at: nil)
                                   .update_all(removal_acknowledged_at: Time.current)
      end

      def removal_acknowledged?(wrapper_id)
        ExternalProjectionLinkBoost.where(wrapper_status_id: wrapper_id, state: 'undone')
                                   .where.not(removal_acknowledged_at: nil).exists?
      end

      def enqueue_removals(wrapper_ids)
        Array(wrapper_ids).compact.each { |id| LinkWrapperRemovalWorker.perform_async(id) }
      end
    end
  end
end
