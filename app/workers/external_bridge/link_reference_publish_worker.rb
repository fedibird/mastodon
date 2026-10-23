# frozen_string_literal: true

module ExternalBridge
  # Retries distribution of one reference note until published_at is set.
  # EnsureReference enqueues this after the mapping commits. A second run,
  # including one after the Redis publish key has expired, does not enqueue
  # distribution again.
  class LinkReferencePublishWorker
    include Sidekiq::Worker

    sidekiq_options retry: 5

    def perform(mapping_id)
      ApplicationRecord.transaction(requires_new: true) do
        row = ExternalProjectionLinkReference.lock('FOR UPDATE').find_by(id: mapping_id)
        publish_locked!(row)
      end

      LinkSharing::BoostSchedule.enqueue_for_mapping!(mapping_id) if published?(mapping_id)
    end

    private

    # Create is done. Boosts of this mapping that were waiting for it may now
    # announce. Pushed after the transaction so the mark is visible to them.
    def published?(mapping_id)
      ExternalProjectionLinkReference.where(id: mapping_id).where.not(published_at: nil).exists?
    end

    def publish_locked!(row)
      return if row.nil? || row.published_at.present? || row.broken? || row.reference_status_id.nil?

      status = Status.find_by(id: row.reference_status_id)
      return if status.nil? || status.deleted_at.present?
      return if ExternalBridge::ProjectionPrivacy.private_status?(status)

      LinkSharing::Checkpoints.fire(:before_reference_publish, row.id)
      PublishStatusService.new.call(status)
      row.update!(published_at: Time.current)
    end
  end
end
