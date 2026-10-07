# frozen_string_literal: true

class ActivityPub::SynchronizeGroupAffiliationsWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', lock: :until_executed

  def perform(account_id, options = {})
    options = options.with_indifferent_access

    ActivityPub::FetchGroupAffiliationsService.new.call(
      Account.find(account_id),
      collection: options[:collection]
    )
  rescue ActiveRecord::RecordNotFound
    true
  end
end
