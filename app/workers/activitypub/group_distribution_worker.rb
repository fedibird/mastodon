# frozen_string_literal: true

class ActivityPub::GroupDistributionWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'push'

  def perform(status_id)
    status = Status.find(status_id)
    groups = Account.local.groups.where(id: status.mentions.select(:account_id)).joins(:passive_relationships)

    groups.each do |group|
      next unless status.account.following?(group)

      visibility = ActivityPub::GroupAnnounce.visibility_for(status, group)

      ReblogService.new.call(group, status, { visibility: visibility })
    end
  rescue ActiveRecord::RecordNotFound
    true
  end
end
