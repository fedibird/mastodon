# frozen_string_literal: true

class UnfavouriteService < BaseService
  include Payloadable

  def call(account, status, viewer_user: nil)
    if ExternalBridge::ProjectionPrivacy.private_status?(status)
      viewer_id = viewer_user&.id || ExternalBridge::Viewer.user_id
      raise Mastodon::NotPermittedError unless ExternalBridge::ProjectionAccess.allow?(viewer_id, status)
    end

    favourite = Favourite.find_by!(account: account, status: status)
    favourite.destroy!
    create_notification(favourite) if !status.account.local? && status.account.activitypub?
    favourite
  end

  private

  def create_notification(favourite)
    status = favourite.status
    ActivityPub::DeliveryWorker.perform_async(build_json(favourite), favourite.account_id, status.account.inbox_url)
  end

  def build_json(favourite)
    Oj.dump(serialize_payload(favourite, ActivityPub::UndoLikeSerializer))
  end
end
