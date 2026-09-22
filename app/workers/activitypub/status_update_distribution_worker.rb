# frozen_string_literal: true

class ActivityPub::StatusUpdateDistributionWorker < ActivityPub::DistributionWorker
  def perform(status_id, options = {})
    @options = options.is_a?(Hash) ? options.symbolize_keys : {}
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

  def deliver_to_parent!
    inbox_url = @status.conversation&.inbox_url
    return if inbox_url.present? && excluded_inboxes.include?(inbox_url)

    super
  end

  def inboxes
    @inboxes ||= StatusReachFinder.new(@status).inboxes - excluded_inboxes
  end

  # Inboxes that already received a Create for a remote mention introduced
  # by this edit. Personal and shared inboxes are both listed so the same
  # server is not offered the Create and the Update.
  def excluded_inboxes
    @excluded_inboxes ||= Array(@options[:exclude_inboxes]).map(&:to_s)
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
