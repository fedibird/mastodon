# frozen_string_literal: true

class ActivityPub::StatusUpdateDistributionWorker < ActivityPub::DistributionWorker
  def perform(status_id)
    @status  = Status.find(status_id)
    @account = @status.account

    return if skip_distribution?

    if delegate_distribution?
      deliver_to_parent!
    else
      deliver_to_inboxes!
    end

    relay! if relayable?
  rescue ActiveRecord::RecordNotFound
    true
  end

  private

  def skip_distribution?
    @status.personal_visibility?
  end

  # StatusReachFinder already includes public relays. A second relay
  # pass would deliver the same Update twice.
  def relayable?
    false
  end

  def inboxes
    @inboxes ||= StatusReachFinder.new(@status).inboxes
  end

  def payload(software)
    @update_payload ||= {}
    software = '(general)' if software.blank?
    @update_payload[software] ||= Oj.dump(serialize_payload(activity, ActivityPub::ActivitySerializer, signer: @account, software: software))
  end

  def activity
    ActivityPub::ActivityPresenter.new(
      id: "#{ActivityPub::TagManager.instance.uri_for(@status)}#updates/#{@status.edited_at.to_i}",
      type: 'Update',
      actor: ActivityPub::TagManager.instance.uri_for(@status.account),
      published: @status.edited_at,
      expiry: @status.expiry,
      to: ActivityPub::TagManager.instance.to(@status),
      cc: ActivityPub::TagManager.instance.cc(@status),
      virtual_object: @status
    )
  end
end
