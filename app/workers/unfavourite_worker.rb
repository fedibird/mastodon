# frozen_string_literal: true

class UnfavouriteWorker
  include Sidekiq::Worker

  def perform(account_id, status_id, user_id = nil)
    status = Status.find(status_id)
    if ExternalBridge::ProjectionPrivacy.private_status?(status)
      return true if user_id.nil? || !ExternalBridge::ProjectionAccess.allow?(user_id, status)

      UnfavouriteService.new.call(Account.find(account_id), status, viewer_user: User.find(user_id))
    else
      UnfavouriteService.new.call(Account.find(account_id), status)
    end
  rescue ActiveRecord::RecordNotFound, Mastodon::NotPermittedError
    true
  end
end
