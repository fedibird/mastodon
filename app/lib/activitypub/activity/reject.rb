# frozen_string_literal: true

class ActivityPub::Activity::Reject < ActivityPub::Activity
  def perform
    return reject_follow_for_relay if relay_follow?

    unless follow_request_from_object.nil?
      # Capture the local requester before reject! destroys the FollowRequest.
      rejected_account = follow_request_from_object.account
      follow_request_from_object.reject!
      record_inbound_follow_reject(rejected_account)
      return
    end

    return UnfollowService.new.call(follow_from_object.account, @account) unless follow_from_object.nil?

    if @object.is_a?(Hash)
      reject_embedded_follow if @object['type'] == 'Follow'
    else
      # Bare follow-request URI with no surviving FollowRequest/Follow: on a
      # re-delivery, the first Reject already destroyed the FollowRequest, so
      # repair the missed ledger event by correlating the follow-request URI to
      # the outbound follow interaction that was recorded when we sent it.
      repair_inbound_follow_reject_from_uri
    end
  end

  private

  def reject_embedded_follow
    target_account = account_from_uri(target_uri)

    return if target_account.nil? || !target_account.local?

    follow_request = FollowRequest.find_by(account: target_account, target_account: @account)
    follow_request&.reject!

    # Record the inbound follow-request rejection. The rejected account is taken
    # from the embedded Follow's actor, so this still works (and repairs a missed
    # ledger event on re-delivery) after reject! has destroyed the FollowRequest.
    record_inbound_follow_reject(target_account)

    UnfollowService.new.call(target_account, @account) if target_account.following?(@account)
  end

  # Re-delivery repair for the bare-follow-request-URI shape. reject! has already
  # destroyed the FollowRequest, so the rejected local requester cannot be read
  # from it (its URI is an opaque payload id that does not encode the account).
  # Instead correlate the follow-request URI to the outbound follow interaction
  # recorded at request time under the same activity identity
  # (activitypub_follow:<uri>) and recover the requester from its actor. Nothing
  # is repaired only when that anchor is also missing (a double recorder failure).
  def repair_inbound_follow_reject_from_uri
    return if object_uri.blank?

    interaction = ModerationInteractionEvent.find_by(source_event_key: "activitypub_follow:#{object_uri}")
    return if interaction.nil?

    rejected_account = interaction.actor_subject&.account
    record_inbound_follow_reject(rejected_account)
  end

  # Inbound Reject of a local account's follow request: the remote actor rejected
  # the local requester. Keyed on the Reject activity identity (not the
  # destroyed FollowRequest) so it is stable across re-delivery. Failure-tolerant.
  def record_inbound_follow_reject(rejected_account)
    return if rejected_account.nil? || !rejected_account.local? || @json['id'].blank?

    Moderation::EventRecorder.record_rejection(
      rejector: @account,
      rejected: rejected_account,
      event_type: :follow_reject,
      source_event_key: "activitypub_follow_reject:#{@json['id']}"
    )
  end

  def reject_follow_for_relay
    relay.update!(state: :rejected)
  end

  def relay
    @relay ||= Relay.find_by(follow_activity_id: object_uri) unless object_uri.nil?
  end

  def relay_follow?
    relay.present?
  end

  def target_uri
    @target_uri ||= value_or_id(@object['actor'])
  end
end
