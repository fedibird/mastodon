# frozen_string_literal: true

class Form::StatusBatch
  include ActiveModel::Model
  include AccountableConcern

  attr_accessor :status_ids, :action, :current_account

  def save
    case action
    when 'nsfw_on', 'nsfw_off'
      change_sensitive(action == 'nsfw_on')
    when 'expire'
      expire_statuses
    when 'delete'
      delete_statuses
    end
  end

  private

  def change_sensitive(sensitive)
    media_attached_status_ids = MediaAttachment.where(status_id: status_ids).pluck(:status_id)

    ApplicationRecord.transaction do
      Status.where(id: media_attached_status_ids).reorder(nil).find_each do |status|
        status.update!(sensitive: sensitive)
        log_action :update, status
      end
    end

    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  def expire_statuses
    Status.where(id: status_ids).reorder(nil).find_each do |status|
      if status.reblog?
        reblog = status.reblog
        reblog.discard
        RemoveStatusService.new.call(reblog, mark_expired: true)
        log_action :expire, reblog
        RemovalWorker.perform_async(status.id, { 'immediate' => true })
        Tombstone.find_or_create_by(uri: status.uri, account: status.account, by_moderator: true)
        log_action :destroy, status
      else
        RemoveStatusService.new.call(status, mark_expired: true)
        log_action :expire, status
      end
    end

    true
  end

  def delete_statuses
    Status.include_expired.where(id: status_ids).reorder(nil).find_each do |status|
      status.discard
      RemovalWorker.perform_async(status.id, { 'immediate' => true })
      Tombstone.find_or_create_by(uri: status.uri, account: status.account, by_moderator: true)
      log_action :destroy, status
    end

    true
  end
end
