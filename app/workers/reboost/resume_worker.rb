# frozen_string_literal: true

class Reboost::ResumeWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8

  def perform(operation_id)
    operation = ReboostOperation.find_by(id: operation_id)
    return if operation.nil?

    operation.reload
    if operation.terminal?
      Reboost::UndoDelivery.deliver!(operation)
      return
    end

    if operation.state == 'federating'
      Reboost::DeliveryResume.resume!(operation)
      return
    end

    return unless operation.state == 'pending'

    if operation.reboost && !operation.account.user&.reboost_enabled?
      Reboost::PendingTransition.cancel_disabled!(operation)
      return
    end

    Reboost::Placement.resume!(operation)
  rescue Mastodon::ReboostCooldownError
    operation.reload
    Reboost::Placement.fail_open!(operation, 'cooldown') if operation.state == 'pending'
  rescue Mastodon::ReboostPendingError
    true
  end
end
