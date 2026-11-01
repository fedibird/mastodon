# frozen_string_literal: true

# Hourly recovery for private group-request icons. Sweep removes objects
# that no row references and that are older than the draft grace period.
# purge_terminal retries cancelled and rejected rows. Handoff recovery
# retries approved copies and private-original deletion. One storage error
# does not stop the rest of the pass.
class Scheduler::GroupCreationIconsScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    run_step('sweep') { GroupCreationIcons::Sweep.call }
    run_step('purge') { GroupCreationIcons::Purge.purge_terminal }
    run_step('handoff') { GroupCreationIcons::HandoffRecovery.call }
  end

  private

  def run_step(name)
    yield
  rescue StandardError => e
    Rails.logger.error("Group creation icon #{name} failed error=#{e.class}")
  end
end
