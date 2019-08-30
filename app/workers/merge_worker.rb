# frozen_string_literal: true

class MergeWorker
  include Sidekiq::Worker

  def perform(from_account_id, into_account_id, public_only = false)
    FeedManager.instance.merge_into_home(Account.find(from_account_id), Account.find(into_account_id), public_only)
  rescue ActiveRecord::RecordNotFound
    true
  ensure
    Redis.current.del("account:#{into_account_id}:regeneration")
  end
end
