# frozen_string_literal: true

class RemoveFromFollowersService < BaseService
  include Payloadable

  def call(source_account, target_accounts)
    source_account.passive_relationships.where(account_id: target_accounts).find_each do |follow|
      follower = follow.account
      follow.destroy

      Moderation::EventRecorder.record_rejection(rejector: source_account, rejected: follower, event_type: :remove_follower, source_record: follow)

      if source_account.local? && !follower.local? && follower.activitypub?
        create_notification(follow)
      end
    end
  end

  private

  def create_notification(follow)
    ActivityPub::DeliveryWorker.perform_async(build_json(follow), follow.target_account_id, follow.account.inbox_url)
  end

  def build_json(follow)
    Oj.dump(serialize_payload(follow, ActivityPub::RejectFollowSerializer))
  end
end
