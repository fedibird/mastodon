# frozen_string_literal: true

# Puts expired inflight directory ids back on the pending set and queues one
# drain. The scheduled flag is not proof that a Sidekiq job still exists.
class Scheduler::GroupDirectoryIndexRecoveryScheduler
  include Sidekiq::Worker

  sidekiq_options queue: 'scheduler', retry: 0

  def perform
    GroupDirectory::Indexing.recover!
  end
end
