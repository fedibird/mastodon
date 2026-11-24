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
  def resume!(operation)
    return if operation.nil?

    operation.reload
    return unless operation.state == 'federating'

    status = Status.find_by(id: operation.new_status_id)
    enqueue_home!(operation, status) if status
    enqueue_notification!(operation, status) if status
    enqueue_federation!(operation)
  end

  def resume_outstanding!
    ReboostOperation.where(state: 'federating').where('local_enqueued_at IS NULL OR notification_enqueued_at IS NULL OR federation_enqueued_at IS NULL').find_each(batch_size: 100) do |operation|
      resume!(operation)
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

      Reboost::FederationWorker.perform_in(Reboost::FEDERATION_GAP, operation.id)
      operation.update!(federation_enqueued_at: Time.current)
    end
  end
end
