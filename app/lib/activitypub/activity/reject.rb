# frozen_string_literal: true

class ActivityPub::Activity::Reject < ActivityPub::Activity
  def perform
    return reject_follow_for_relay if relay_follow?

    unless follow_request_from_object.nil?
      # Capture the local requester before reject! destroys the FollowRequest.
      rejected_account = follow_request_from_object.account
      FollowImport::TargetResponseCorrelator.rejected(follow_request_from_object)
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

    # Do not look up or destroy a FollowRequest by account pair. perform already
    # handled the exact URI match via follow_request_from_object, so a pair-only
    # hit here is necessarily a URI mismatch — typically a stale protocol ack
    # for an older Follow arriving after a newer request for the same pair.
    # Record only when the embedded Follow id correlates to a real outbound
    # Follow from this server (actor/target identity checks included).
    if outbound_follow_anchor_for?(object_uri, claimed_requester: target_account)
      record_inbound_follow_reject(target_account)
    end

    UnfollowService.new.call(target_account, @account) if target_account.following?(@account)
  end

  # Re-delivery repair for the bare-follow-request-URI shape. reject! has already
  # destroyed the FollowRequest, so the rejected local requester cannot be read
  # from it (its URI is an opaque payload id that does not encode the account).
  # Instead correlate the follow-request URI to the outbound follow interaction
  # recorded at request time under the direction-specific activity identity
  # (activitypub_outbound_follow:<uri>) and recover the requester from its actor.
  def repair_inbound_follow_reject_from_uri
    rejected_account = local_requester_from_outbound_follow_anchor(object_uri)
    return if rejected_account.nil?

    record_inbound_follow_reject(rejected_account)
  end

  # URI equality alone must NOT bind identities: a leaked/reused/malicious object
  # URI must not let remote actor B cause us to record "B rejected local A" from
  # an anchor that was actually "A -> remote C". The outbound-follow anchor must
  # satisfy every invariant of the follow this Reject claims to reject, and we
  # fail closed otherwise.
  def local_requester_from_outbound_follow_anchor(follow_id)
    return if follow_id.blank?

    interaction = ModerationInteractionEvent.find_by(
      source_event_key: "activitypub_outbound_follow:#{follow_id}",
      event_type: :follow
    )
    return if interaction.nil?

    # The anchor's actor must be the local requester...
    rejected_account = interaction.actor_subject&.account
    return if rejected_account.nil? || !rejected_account.local?

    # ...and its target must be the very remote actor now sending this Reject.
    return unless interaction.target_subject&.account_id == @account.id

    rejected_account
  end

  def outbound_follow_anchor_for?(follow_id, claimed_requester:)
    return false if claimed_requester.nil?

    local_requester_from_outbound_follow_anchor(follow_id) == claimed_requester
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
