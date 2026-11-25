# frozen_string_literal: true

# Links a committed boost to its operation before Redis or a queue write.
# A crash between those steps resumes the same wrapper.
module Reboost::CreatedBoost
  private

  # A second stamp would start the five minutes over after a crash.
  def stamp_cooldown_once!
    return if ReboostCooldown.remaining_seconds(account.id, original.id).positive?

    ReboostCooldown.stamp!(account.id, original.id)
  end

  def attach_created!(created, existing)
    return unless resumed_operation || ordered_undo? || existing&.local?

    federation_operation(created, existing&.local? ? existing : nil)
  end

  # Queues run only after the operation points at this wrapper.
  def publish_created!(created, existing)
    operation = federation_record_for(created)
    distribute_locally!(created, federate: existing.nil? && !ordered_undo? && operation.nil?, operation: operation)
    return if operation.nil?

    enqueue_federation!(operation)
    Reboost::Log.emit('federation_scheduled', operation_id: operation.id, gap_seconds: Reboost::FEDERATION_GAP.to_i)
  end

  def federation_record_for(created)
    operation = @recovery || resumed_operation
    operation if operation&.new_status_id == created.id && operation.state == 'federating'
  end

  # The wrapper committed and the process stopped before the operation link.
  def resume_unlinked_wrapper!
    operation = resumed_operation
    return if operation.nil?

    operation.reload
    return unless operation.state == 'pending'

    created = account.statuses.where(reblog_of_id: original.id).where.not(id: operation.old_status_id).order(:id).last
    return if created.nil?

    stamp_cooldown_once!
    attach_created!(created, nil)
    remember_idempotency!(created)
    publish_created!(created, nil)
    created
  end
end
