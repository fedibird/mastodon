# frozen_string_literal: true

class ActivityPub::Activity::Follow < ActivityPub::Activity
  include Payloadable

  def perform
    target_account = account_from_uri(object_uri)

    return if target_account.nil? || !target_account.local? || delete_arrived_first?(@json['id'])

    # Update id of already-existing follow requests
    existing_follow_request = ::FollowRequest.find_by(account: @account, target_account: target_account)
    unless existing_follow_request.nil?
      existing_follow_request.update!(uri: @json['id'])
      record_inbound_follow(target_account)
      return
    end

    if target_account.blocking?(@account) || target_account.domain_blocking?(@account.domain) || target_account.moved? || target_account.instance_actor?
      reject_follow_request!(target_account)
      return
    end

    # Fast-forward repeat follow requests
    existing_follow = ::Follow.find_by(account: @account, target_account: target_account)
    unless existing_follow.nil?
      existing_follow.update!(uri: @json['id'])
      AuthorizeFollowService.new.call(@account, target_account, skip_follow_request: true, follow_request_uri: @json['id'])
      record_inbound_follow(target_account)
      return
    end

    follow_request = FollowRequest.create!(account: @account, target_account: target_account, uri: @json['id'])

    if target_account.locked? || @account.silenced? || @account.bot? && target_account.user.setting_confirm_follow_from_bot
      NotifyService.new.call(target_account, :follow_request, follow_request)
    else
      AuthorizeFollowService.new.call(@account, target_account)
      NotifyService.new.call(target_account, :follow, ::Follow.find_by(account: @account, target_account: target_account))
    end

    # Record the inbound follow contact against the surviving durable record
    # (the Follow if it was auto-accepted, else the FollowRequest) so first
    # delivery and any re-delivery share a stable source_event_key. This dedupes
    # ordinary re-delivery and lets re-delivery repair a ledger event that a
    # transient recorder failure missed on an earlier delivery.
    record_inbound_follow(target_account)
  end

  def reject_follow_request!(target_account)
    json = Oj.dump(serialize_payload(FollowRequest.new(account: @account, target_account: target_account, uri: @json['id']), ActivityPub::RejectFollowSerializer))
    ActivityPub::DeliveryWorker.perform_async(json, target_account.id, @account.inbox_url)
  end

  private

  def record_inbound_follow(target_account)
    source_record = ::Follow.find_by(account: @account, target_account: target_account) ||
                    ::FollowRequest.find_by(account: @account, target_account: target_account)
    return if source_record.nil?

    # Key on the ActivityPub Follow activity identity rather than the relationship
    # record, so the event stays deduped across the FollowRequest -> Follow
    # conversion: a locked target's pending request may be accepted (request
    # destroyed, Follow created) and the same activity later re-delivered. Both a
    # FollowRequest-backed and a Follow-backed recording then share one key.
    # Falls back to the record-derived key only when the activity has no id.
    Moderation::EventRecorder.record_interaction(
      actor: @account,
      target: target_account,
      event_type: :follow,
      source_record: source_record,
      source_event_key: inbound_follow_source_event_key
    )
  end

  def inbound_follow_source_event_key
    return if @json['id'].blank?

    "activitypub_follow:#{@json['id']}"
  end
end
