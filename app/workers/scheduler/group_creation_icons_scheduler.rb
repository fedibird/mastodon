# frozen_string_literal: true

# Hourly recovery for private group-request icons. Sweep removes objects
# that no row references and that are older than the draft grace period.
# purge_terminal retries cancelled and rejected rows. One storage error
# does not stop the rest of the pass.
class Scheduler::GroupCreationIconsScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    GroupCreationIcons::Sweep.call
  rescue StandardError => e
    Rails.logger.error("Group creation icon sweep failed error=#{e.class}")
  ensure
    GroupCreationIcons::Purge.purge_terminal
  end
end
