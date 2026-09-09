# frozen_string_literal: true

class MuteService < BaseService
  def call(account, target_account, notifications: nil, duration: 0)
    return if account.id == target_account.id

    mute = account.mute!(target_account, notifications: notifications, duration: duration)

    Moderation::EventRecorder.record_rejection(
      rejector: account,
      rejected: target_account,
      event_type: :mute,
      source_record: mute,
      metadata: { hide_notifications: mute.hide_notifications? }
    )

    if mute.hide_notifications?
      BlockWorker.perform_async(account.id, target_account.id)
    else
      MuteWorker.perform_async(account.id, target_account.id)
    end

    DeleteMuteWorker.perform_at(duration.seconds, mute.id) if duration != 0

    mute
  end
end
