# frozen_string_literal: true

class Reboost::ResumeWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8

  def perform(operation_id)
    operation = ReboostOperation.find_by(id: operation_id)
    return if operation.nil? || operation.terminal?

    if operation.reboost && !operation.account.user&.reboost_enabled?
      operation.update!(state: 'cancelled', error_code: 'reboost_disabled', completed_at: Time.current)
      Reboost::FederationWorker.perform_async(operation.id) if operation.undo_payload.present?
      Reboost::Log.emit('cancelled', operation_id: operation.id, error: 'reboost_disabled')
      return
    end

    Reboost::Placement.resume!(operation)
  rescue Mastodon::ReboostCooldownError
    Reboost::Placement.fail_open!(operation, 'cooldown')
  rescue Mastodon::ReboostPendingError
    true
  end
end
