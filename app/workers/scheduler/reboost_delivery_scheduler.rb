# frozen_string_literal: true

class Scheduler::ReboostDeliveryScheduler
  include Sidekiq::Worker

  sidekiq_options queue: 'scheduler', retry: 0

  def perform
    Reboost::DeliveryResume.resume_outstanding!
    RemoteReboostHold.schedule_outstanding!
  end
end
