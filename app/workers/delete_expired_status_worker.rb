# frozen_string_literal: true

class DeleteExpiredStatusWorker
  include Sidekiq::Worker

  sidekiq_options retry: 0, dead: false

  def perform(status_id)
    @status = Status.include_expired.find(status_id)
    RemoveStatusService.new.call(@status, redraft: false)
  rescue ActiveRecord::RecordNotFound
    true
  end
end
