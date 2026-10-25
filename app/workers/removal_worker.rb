# frozen_string_literal: true

class RemovalWorker
  include Sidekiq::Worker

  def perform(status_id, options = {})
    # A wrapper of an ended E4 link share whose removal already ran (a repeated
    # push from the recovery scan) is not removed, and not Undone, a second time.
    return true if ExternalBridge::LinkSharing::Retire.removal_acknowledged?(status_id)

    RemoveStatusService.new.call(Status.include_expired.with_discarded.find(status_id), **options.symbolize_keys)
    ExternalBridge::LinkSharing::Retire.acknowledge_removal!(status_id)
  rescue ActiveRecord::RecordNotFound
    true
  end
end
