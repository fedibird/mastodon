# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Ends active boost rows and takes their wrapper Statuses away. An announced
    # wrapper is discarded and then removed by RemovalWorker, like
    # Api::V1::Statuses::ReblogsController does for an ordinary unreblog. The
    # reference note and the projection are not touched.
    #
    # Every method here expects the caller to hold the rows FOR UPDATE inside a
    # transaction and to hand the returned wrapper ids to enqueue_removals
    # after that transaction commits. Only a wrapper whose Announce was already
    # handed to distribution needs RemovalWorker, which sends the Undo and
    # then removes the row. A wrapper that never left the server has no remote
    # copy and no timeline entry to take back, so it is removed here. Removing
    # it matters: Status validates one boost per Account and note, and that
    # check does not look at discarded rows, so a left-over row would block the
    # next share.
    module Retire
      module_function

      ORPHAN_BATCH = 20

      # @return [Integer, nil] wrapper id that needs RemovalWorker
      def end!(boost, reason:)
        return nil unless boost.active?

        boost.update!(state: 'undone', undone_at: Time.current, ended_reason: reason.to_s)
        wrapper = Status.unscoped.find_by(id: boost.wrapper_status_id)
        return nil if wrapper.nil?

        if boost.announced_at.blank?
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

      def enqueue_removals(wrapper_ids)
        Array(wrapper_ids).compact.each { |id| RemovalWorker.perform_async(id) }
      end
    end
  end
end
