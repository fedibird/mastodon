# frozen_string_literal: true

# Picks up founding-owner follows that were approved but not finished.
# One pass enqueues at most 20 existing rows. It does not scan old groups
# and it does not turn the creation-request setting on.
class Scheduler::GroupInitialFollowsScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    GroupInitialFollows::Recovery.call
  end
end
