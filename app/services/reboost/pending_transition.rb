# frozen_string_literal: true

# Pending is the only state a resume may turn into a new boost or a failure.
# A federating or finished row keeps the stage it already reached.
class Reboost::PendingTransition
  include Redisable
  include Lockable

  def self.fail!(operation, code)
    return if operation.nil?

    new(operation).fail!(code)
  end

  def self.cancel_disabled!(operation)
    return if operation.nil?

    new(operation).cancel_disabled!
  end

  # :continue, :stop, or the boost created by an earlier pass.
  def self.resumed_result(operation)
    return :continue if operation.nil?

    operation.reload
    if operation.state == 'federating'
      Reboost::DeliveryResume.resume!(operation)
      return Status.find_by(id: operation.new_status_id) || :stop
    end
    return :stop if operation.state != 'pending'

    :continue
  end

  def initialize(operation)
    @operation = operation
  end

  def fail!(code)
    with_redis_lock(lock_name) do
      operation.reload
      if operation.state == 'federating' && code != 'missing_status'
        Reboost::DeliveryResume.resume!(operation)
        return
      end
      return unless operation.state == 'pending' || (code == 'missing_status' && operation.state == 'federating')

      operation.fail!(code)
      Reboost::UndoDelivery.settle!(operation)
    end
  end

  def cancel_disabled!
    return unless operation.reboost

    with_redis_lock(lock_name) do
      operation.reload
      return unless operation.state == 'pending'
      return if operation.account.user&.reboost_enabled?

      operation.update!(state: 'cancelled', error_code: 'reboost_disabled', completed_at: Time.current)
      Reboost::UndoDelivery.settle!(operation)
      Reboost::Log.emit('cancelled', operation_id: operation.id, error: 'reboost_disabled')
    end
  end

  private

  attr_reader :operation

  def lock_name
    "reboost:#{operation.account_id}:#{operation.reblog_of_id}"
  end
end
