# frozen_string_literal: true

class Reboost::DeliveryResume
  include Redisable
  include Lockable

  def self.resume!(operation)
    new.resume!(operation)
  end

  def self.resume_outstanding!
    new.resume_outstanding!
  end

  def self.enqueue_federation!(operation)
    new.enqueue_federation!(operation)
  end

  # A federating row is the record that delivery was not finished. The
  # timestamps are written only after the matching enqueue returns, so a
  # raised enqueue stays eligible for this pass.
  def self.deliverable_replacement?(operation)
    operation&.state == 'federating' && operation.new_status_id.present? && operation.removal_finished_at.present?
  end

  def resume!(operation)
    return if operation.nil?

    operation.reload
    return unless self.class.deliverable_replacement?(operation)

    status = Status.find_by(id: operation.new_status_id)
    enqueue_home!(operation, status) if status
    enqueue_notification!(operation, status) if status
    enqueue_federation!(operation)
  end

  # find_each walks every matching row, 100 at a time. One row that cannot
  # take its lock does not stop the rows after it.
  def resume_outstanding!
    ready = ReboostOperation.where(state: 'federating').where.not(new_status_id: nil).where.not(removal_finished_at: nil)
    ready.where('local_enqueued_at IS NULL OR notification_enqueued_at IS NULL OR federation_enqueued_at IS NULL').find_each(batch_size: 100) do |operation|
      resume!(operation)
    rescue StandardError
      next
    end
    resume_stranded_pending!
    resume_unsent_undos!
  end

  # A terminal row can still owe its saved Undo when the enqueue raised.
  # The next pass sends that Undo and does not create another wrapper.
  def resume_unsent_undos!
    ReboostOperation.where(state: %w(cancelled failed), undo_enqueued_at: nil).where.not(undo_payload: [nil, '']).find_each(batch_size: 100) do |operation|
      Reboost::UndoDelivery.settle!(operation)
    rescue StandardError
      next
    end
  end

  # The same resume worker used after a 202 applies the disabled, cooldown,
  # and cancel transitions. One row's error does not stop the later rows.
  def resume_stranded_pending!
    ReboostOperation.where(state: 'pending').where('updated_at < ?', 30.seconds.ago).find_each(batch_size: 100) do |operation|
      Reboost::ResumeWorker.new.perform(operation.id)
    rescue StandardError
      next
    end
  end

  def enqueue_home!(operation, status)
    return if operation.nil? || status.nil?

    with_redis_lock("reboost:local_enqueue:#{operation.id}") do
      operation.reload
      return if operation.local_enqueued_at.present?

      DistributionWorker.perform_async(status.id)
      operation.update!(local_enqueued_at: Time.current)
    end
  end

  # The timestamp is written only after the enqueue returns, so a raised
  # notification call stays eligible for the next pass and is not sent twice.
  def enqueue_notification!(operation, reblog)
    return if operation.nil?

    original = Status.find_by(id: operation.reblog_of_id)
    notify = reblog.present? && original&.account&.local? && !reblog.account.group?

    with_redis_lock("reboost:notification_enqueue:#{operation.id}") do
      operation.reload
      return if operation.notification_enqueued_at.present?

      LocalNotificationWorker.perform_async(original.account_id, reblog.id, reblog.class.name, 'reblog') if notify
      operation.update!(notification_enqueued_at: Time.current)
    end
  end

  def enqueue_federation!(operation)
    return if operation.nil?

    with_redis_lock("reboost:federation_enqueue:#{operation.id}") do
      operation.reload
      return if operation.federation_enqueued_at.present? || operation.terminal?
      return unless self.class.deliverable_replacement?(operation)

      Reboost::FederationWorker.perform_in(Reboost::FEDERATION_GAP, operation.id)
      operation.update!(federation_enqueued_at: Time.current)
    end
  end
end
