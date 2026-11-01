# frozen_string_literal: true

class ActivityPub::GroupDistributionWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'push'

  def perform(status_id)
    status = Status.find(status_id)
    groups = Account.local.groups.where(id: status.mentions.active.select(:account_id))

    groups.each do |group|
      next unless ActivityPub::GroupAnnounce.announce?(status, group)

      ReblogService.new.call(group, status, { visibility: ActivityPub::GroupAnnounce.visibility_for(status, group) })
    end
  rescue ActiveRecord::RecordNotFound
    true
  end
end
