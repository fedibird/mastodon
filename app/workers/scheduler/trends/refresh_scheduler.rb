# frozen_string_literal: true

class Scheduler::Trends::RefreshScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  def perform
    return unless Setting.trends

    Trends.refresh!
    TrendingTags.notify_unreviewed!
  end
end
