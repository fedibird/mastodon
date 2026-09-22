# frozen_string_literal: true

class PollExpirationNotifyWorker
  include Sidekiq::Worker

  sidekiq_options lock: :until_executed

  def self.remove_from_scheduled(poll_id)
    Sidekiq::ScheduledSet.new.scan(name).each do |job|
      job.delete if job.klass == name && job.args.first == poll_id
    end
  end

  def perform(poll_id)
    poll = Poll.find(poll_id)

    # Notify poll owner and remote voters
    if poll.local?
      ActivityPub::DistributePollUpdateWorker.perform_async(poll.status.id)
      NotifyService.new.call(poll.account, :poll, poll)
    end

    # Notify local voters
    poll.votes.includes(:account).group(:account_id).select(:account_id).map(&:account).select(&:local?).each do |account|
      NotifyService.new.call(account, :poll, poll)
    end
  rescue ActiveRecord::RecordNotFound
    true
  end
end
