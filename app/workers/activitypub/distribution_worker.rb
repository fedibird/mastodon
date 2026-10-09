# frozen_string_literal: true

class ActivityPub::DistributionWorker
  include Sidekiq::Worker
  include Payloadable

  sidekiq_options queue: 'push'

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
    @status.direct_visibility?
  end

  def delegate_distribution?
    @status.limited_visibility? && @status.reply? && !@status.conversation.local?
  end

  def relayable?
    @status.public_visibility?
  end

  def node_software_name(inbox_url)
    Node.find_domain(Addressable::URI.parse(inbox_url).normalized_host.to_s.downcase)&.software_name
  end

  def deliver_to_parent!
    return if @status.conversation.inbox_url.blank?

    ActivityPub::DeliveryWorker.perform_async(payload(node_software_name(@status.conversation.inbox_url)), @account.id, @status.conversation.inbox_url)
  end

  def deliver_to_inboxes!
    observation_key = safe_group_observation_key
    audience_inbox = observation_key.present? ? @status.audience_account&.inbox_url.presence : nil
    targets = inboxes

    job_ids = ActivityPub::DeliveryWorker.push_bulk(targets) do |inbox_url|
      [payload(node_software_name(inbox_url)), @account.id, inbox_url, delivery_options_for(inbox_url, observation_key, audience_inbox)]
    end

    record_observed_queue(observation_key, audience_inbox, targets, job_ids)
  end

  # sidekiq-bulk 0.2.0 forwards to Sidekiq 7.3 Client#push_bulk.
  # The returned array matches `targets` in order. A jid means that
  # payload was in a raw_push which returned; nil means client
  # middleware declined it. An exception returns no array, and earlier
  # batches may already be in Redis, so a missing mark is not proof
  # the group inbox job was absent. Inbox dedup stays in
  # `with_audience_inbox`.
  def record_observed_queue(observation_key, audience_inbox, targets, job_ids)
    return if observation_key.blank?
    return unless group_inbox_jid_returned?(targets, audience_inbox, job_ids)

    PostingContext::GroupFederationObservation.mark_queued(observation_key)
  rescue StandardError => e
    Rails.logger.warn("[ActivityPub::DistributionWorker] group observation queue mark failed: #{e.class}")
  end

  def group_inbox_jid_returned?(targets, audience_inbox, job_ids)
    return false if audience_inbox.blank? || !job_ids.is_a?(Array)

    index = targets.index(audience_inbox)
    return false if index.nil?

    job_ids[index].present?
  end

  def safe_group_observation_key
    PostingContext::GroupFederationObservation.prepare(@status, @account)
  rescue StandardError => e
    Rails.logger.warn("[ActivityPub::DistributionWorker] group observation prepare failed: #{e.class}")
    nil
  end

  def delivery_options_for(inbox_url, observation_key, audience_inbox)
    options = { 'synchronize_followers' => !@status.distributable? }
    return options if observation_key.blank? || inbox_url != audience_inbox

    options.merge(PostingContext::GroupFederationObservation::OPTION => observation_key)
  end

  def inboxes
    # Deliver the status to all followers. If the status is a reply
    # to another local status, also forward it to that status'
    # authors' followers. If the status has limited visibility,
    # deliver it to inboxes of people mentioned (no shared ones).
    # An ActivityPub audience target is delivered to that actor's own
    # inbox, even when shared-inbox delivery would collapse it.

    @inboxes ||= with_audience_inbox(delivery_inboxes)
  end

  def delivery_inboxes
    if @status.limited_visibility?
      DeliveryFailureTracker.without_unavailable(Account.remote.joins(:mentions).merge(@status.mentions).pluck(:inbox_url))
    elsif @status.in_reply_to_local_account? && @status.distributable?
      @account.delivery_followers.or(@status.thread.account.delivery_followers).inboxes
    else
      @account.delivery_followers.inboxes
    end
  end

  def with_audience_inbox(urls)
    inbox_url = @status.audience_account&.inbox_url.presence
    return urls if inbox_url.blank?

    (urls + [inbox_url]).uniq
  end

  def payload(software)
    @payload ||= {}
    software = '(general)' if software.blank?
    @payload[software] ||= Oj.dump(serialize_payload(ActivityPub::ActivityPresenter.from_status(@status), ActivityPub::ActivitySerializer, signer: @account, software: software))
  end

  def relay!
    ActivityPub::DeliveryWorker.push_bulk(Relay.enabled.pluck(:inbox_url)) do |inbox_url|
      [payload(node_software_name(inbox_url)), @account.id, inbox_url]
    end
  end
end
