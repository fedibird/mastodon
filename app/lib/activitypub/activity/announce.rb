# frozen_string_literal: true

class ActivityPub::Activity::Announce < ActivityPub::Activity
  attr_reader :retry_hold

  def perform
    return reject_payload! if delete_arrived_first?(@json['id']) || !related_to_local_activity?
    return reject_payload! if ReboostAnnounceState.superseded?(@account.id, @json['id'])

    @original_status = status_from_object
    return reject_payload! if @original_status.nil? || !announceable?(@original_status)

    # The apply worker already holds this lock. The lock is not reentrant.
    run = proc do
      return reject_payload! if ReboostAnnounceState.superseded?(@account.id, @json['id'])

      @status = Status.find_by(account: @account, reblog: @original_status)
      return if held_for_pending_removal?

      if @status.nil?
        accept_or_hold_new_announce!
      else
        receive_another_announce!
      end
    end

    if @options[:applying_hold]
      run.call
    else
      with_redis_lock(Reboost::AnnounceLock.key(@account.id, @original_status.id), &run)
    end

    @status
  end

  private

  # Undo removes the wrapper and leaves the cooldown. A new id during that
  # window is held, the same as a second id while the first wrapper remains.
  def accept_or_hold_new_announce!
    return accept_new_announce! if @options[:applying_hold]
    return if deliver_known_hold!

    remaining = ReboostCooldown.remaining_seconds(@account.id, @original_status.id)
    if remaining.positive?
      hold_newer_announce!(parsed_published)
      return
    end

    return if defer_to_open_hold?(parsed_published)

    accept_new_announce!
  end

  def accept_new_announce!
    process_status unless @status&.uri == @json['id']
    finish_accepted_announce!
  end

  # Status existing is not the same as acceptance finishing. Follower delivery,
  # the current Announce, and the cooldown can be resumed from the hold.
  # A direct replacement writes that hold before the old boost is removed.
  def finish_accepted_announce!
    hold = current_hold
    adopt_open_hold!(hold) if hold && @consumed_hold.nil?
    hold = @consumed_hold || hold
    if hold&.activity_uri == @json['id']
      deliver_held_announce!(hold)
    else
      distribute(@status)
    end
    expire_queue_action
    remember_current_announce!
    stamp_remote_cooldown_once!
    consume_open_hold!
  end

  def deliver_held_announce!(hold)
    options = hold.delivery_options || {}
    if options['prepared_at'].blank?
      prepare_held_delivery!(@status)
      remember_hold_mark!(hold, 'prepared_at')
    end
    hold.reload
    return if hold.delivery_options['distribution_enqueued_at'].present?

    distribute_to_followers(@status) if deliver_followers?(@status)
    remember_hold_mark!(hold, 'distribution_enqueued_at')
  end

  def prepare_held_delivery!(status)
    crawl_links(status)
    return unless @options[:delivery]

    notify_about_reblog(status) if reblog_of_local_account?(status) && !reblog_by_following_group_account?(status)
    notify_about_mentions(status)
  end

  def deliver_followers?(status)
    @options[:delivery] && (@options[:override_timestamps] || status.within_realtime_window?)
  end

  def remember_hold_mark!(hold, key)
    hold.with_lock do
      hold.update!(delivery_options: (hold.delivery_options || {}).merge(key => Time.current.iso8601))
    end
  end

  def current_hold
    return @consumed_hold if @consumed_hold&.activity_uri == @json['id']

    RemoteReboostHold.find_by(account_id: @account.id, reblog_of_id: @original_status.id, activity_uri: @json['id'])
  end

  def stamp_remote_cooldown_once!
    return if ReboostCooldown.remaining_seconds(@account.id, @original_status.id).positive?

    ReboostCooldown.stamp!(@account.id, @original_status.id)
  end

  def receive_another_announce!
    if @status&.uri == @json['id'] && (current_hold || @options[:applying_hold])
      finish_accepted_announce!
      return
    end

    return postprocess_audience_and_deliver if @status.uri == @json['id'] && @options[:delivered_to_account_id].present?
    return if @status.uri == @json['id']
    return if deliver_known_hold!

    incoming = parsed_published
    current = ReboostAnnounceState.current_for(@account.id, @original_status.id)&.published_at || @status.created_at
    unless incoming && current && incoming > current
      ReboostAnnounceState.supersede!(@account.id, @json['id'], reblog_of_id: @original_status.id)
      return
    end

    if ReboostCooldown.remaining_seconds(@account.id, @original_status.id).positive?
      hold_newer_announce!(incoming)
      return
    end

    return if defer_to_open_hold?(incoming)

    replace_announce!
  rescue Mastodon::RaceConditionError
    hold_newer_announce!(parsed_published)
  end

  def replace_announce!
    previous = @status
    remember_direct_replacement!
    begin
      ReboostAnnounceState.supersede!(@account.id, previous.uri, reblog_of_id: @original_status.id) if previous.uri.present?
      finish_discarded!(previous)
      @original_status.association(:status_stat).reset
      @status = nil
      accept_new_announce!
    rescue StandardError => e
      # The apply worker retries a busy removal itself. Clearing the timestamp
      # here would make that rescue enqueue another inline run.
      mark_direct_replacement_retryable! unless e.is_a?(Mastodon::RaceConditionError) && @options[:applying_hold]
      raise
    end
  end

  # The incoming Announce is recoverable before the old boost is deleted.
  # The inline attempt owns it until delivery finishes or the attempt raises.
  def remember_direct_replacement!
    return if @json['id'].blank?

    existing = RemoteReboostHold.find_by(account_id: @account.id, reblog_of_id: @original_status.id)
    if existing
      return if existing.activity_uri == @json['id']

      ReboostAnnounceState.supersede!(@account.id, existing.activity_uri, reblog_of_id: @original_status.id)
      existing.destroy!
    end

    RemoteReboostHold.create!(
      account: @account,
      reblog_of: @original_status,
      activity_uri: @json['id'],
      published_at: parsed_published,
      available_at: Time.current,
      payload: @json.is_a?(Hash) ? @json.deep_stringify_keys : {},
      apply_enqueued_at: Time.current,
      delivery_options: RemoteReboostHold.normalize_delivery_options(
        'delivery' => @options[:delivery] == true,
        'override_timestamps' => @options[:override_timestamps] == true,
        'delivered_to_account_id' => @options[:delivered_to_account_id],
        'relayed_through_account_id' => @options[:relayed_through_account]&.id
      )
    )
  end

  def mark_direct_replacement_retryable!
    hold = RemoteReboostHold.find_by(account_id: @account.id, reblog_of_id: @original_status.id, activity_uri: @json['id'])
    hold&.update!(apply_enqueued_at: nil)
  end

  # A removal can discard the old wrapper and then lose the distribution lock.
  # The row is invisible to the default scope, so the next attempt has to
  # finish that removal before it creates a replacement.
  def held_for_pending_removal?
    return false if @status.present?

    pending = Status.unscoped.where(account_id: @account.id, reblog_of_id: @original_status.id).where.not(deleted_at: nil)
    return false unless pending.exists?

    pending.find_each { |row| finish_discarded!(row) }
    false
  rescue Mastodon::RaceConditionError
    hold_newer_announce!(parsed_published)
    true
  end

  def finish_discarded!(discarded)
    if discarded.reported?
      RemoveStatusService.new.call(discarded, skip_remote: true, preserve: true)
      Reboost::RetainedCount.release!(@original_status, discarded)
    else
      RemoveStatusService.new.call(discarded, skip_remote: true, immediate: true)
    end
  end

  # A redelivery of the held id keeps that id even when published is missing.
  # The stored payload is used whether or not the old wrapper is still present.
  # Inside the cooldown the hold stays. After it, that payload is applied once.
  def deliver_known_hold!
    return false if @options[:applying_hold]

    hold = RemoteReboostHold.find_by(account_id: @account.id, reblog_of_id: @original_status.id)
    return false unless hold&.activity_uri == @json['id']

    if ReboostCooldown.remaining_seconds(@account.id, @original_status.id).positive?
      hold_newer_announce!(hold.published_at)
      return true
    end

    adopt_open_hold!(hold)
    @json = hold.payload.deep_stringify_keys.with_indifferent_access if hold.payload.is_a?(Hash)
    if @status
      replace_announce!
    else
      accept_new_announce!
    end
    true
  end

  # The cooldown can be over while the newest Announce is still waiting.
  # An older id must not take its place, and a newer id ends that hold.
  def defer_to_open_hold?(incoming)
    return false if @options[:applying_hold]

    hold = RemoteReboostHold.find_by(account_id: @account.id, reblog_of_id: @original_status.id)
    return false if hold.nil?

    if hold.activity_uri == @json['id']
      adopt_open_hold!(hold)
      return false
    end

    if incoming && (hold.published_at.nil? || incoming > hold.published_at)
      ReboostAnnounceState.supersede!(@account.id, hold.activity_uri, reblog_of_id: @original_status.id)
      hold.destroy!
      return false
    end

    ReboostAnnounceState.supersede!(@account.id, @json['id'], reblog_of_id: @original_status.id)
    true
  end

  # A fetch of the held id must keep the inboxes and delivery flag already stored.
  # The hold stays until that accept commits, so a failed accept can still be applied.
  def adopt_open_hold!(hold)
    incoming = {
      'delivery' => @options[:delivery] == true,
      'override_timestamps' => @options[:override_timestamps] == true,
      'delivered_to_account_id' => @options[:delivered_to_account_id],
      'relayed_through_account_id' => @options[:relayed_through_account]&.id,
    }
    merged = RemoteReboostHold.merge_delivery_options(hold.delivery_options, incoming)
    hold.update!(delivery_options: merged)
    apply_merged_delivery!(merged)
    @consumed_hold = hold
  end

  def apply_merged_delivery!(merged)
    ids = Array(merged['delivered_to_account_ids']).compact
    @options[:delivery] = merged['delivery'] == true
    @options[:override_timestamps] = merged['override_timestamps'] == true
    @options[:delivered_to_account_ids] = ids
    @options[:delivered_to_account_id] = ids.first
    relay_id = merged['relayed_through_account_id']
    @options[:relayed_through_account] = Account.find_by(id: relay_id) if relay_id.present?
  end

  def consume_open_hold!
    return if @consumed_hold.nil?

    RemoteReboostHold.where(id: @consumed_hold.id, activity_uri: @json['id']).delete_all
    @consumed_hold = nil
  end

  def hold_newer_announce!(published)
    @retry_hold = true if @options[:applying_hold]
    available_at = Time.current + ReboostCooldown.remaining_seconds(@account.id, @original_status.id).seconds
    RemoteReboostHold.store!(
      @account.id,
      @original_status.id,
      @json['id'],
      published,
      @json.is_a?(Hash) ? @json.deep_stringify_keys : {},
      available_at,
      delivery_options: {
        'delivery' => @options[:delivery] == true,
        'override_timestamps' => @options[:override_timestamps] == true,
        'delivered_to_account_id' => @options[:delivered_to_account_id],
        'relayed_through_account_id' => @options[:relayed_through_account]&.id,
      }
    )
    Reboost::Log.emit('remote_held', account_id: @account.id, status_id: @original_status.id, uri: @json['id'])
  end

  def remember_current_announce!
    ReboostAnnounceState.remember_current!(@account.id, @original_status.id, @json['id'], parsed_published || @status&.created_at)
  end

  def parsed_published
    raw = @json['published']
    return if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def process_status
    @mentions = []
    @params   = {}

    process_status_params
    process_expiry_params
    process_audience

    ApplicationRecord.transaction do
      @status = Status.create!(@params)
      attach_mentions(@status)
    end

    @original_status.tags.each do |tag|
      tag.use!(@account)
    end

    Trends.register!(@status)
  end

  def process_status_params
    @params = begin
      {
        account: @account,
        reblog: @original_status,
        uri: @json['id'],
        created_at: @json['published'],
        override_timestamps: @options[:override_timestamps],
        visibility: visibility_from_audience_with_correction,
        expires_at: @json['expiry'],
        expires_action: :mark,
        fetch: !@options[:delivery],
      }
    end
  end

  def process_expiry_params
    expiry = @object['expiry']&.to_time

    if expiry.nil?
      @params
    elsif expiry <= Time.now.utc + PostStatusService::MIN_EXPIRE_OFFSET
      @params.merge!({
        expired_at: @object['expiry']
      })
    else
      @params.merge!({
        expires_at: @object['expiry'],
        expires_action: :mark,
      })
    end
  end

  def attach_mentions(status)
    @mentions.each do |mention|
      mention.status = status
      mention.save
    end
  end

  def expire_queue_action
    @status.status_expire.queue_action if expires_soon?
  end

  def expires_soon?
    expires_at = @status&.status_expire&.expires_at
    expires_at.present? && expires_at <= Time.now.utc + PostStatusService::MIN_SCHEDULE_OFFSET
  end

  def announceable?(status)
    status.account_id == @account.id || (@account.group? && dereferenced?) || status.distributable? || status.account.mutual?(@account)
  end

  def related_to_local_activity?
    fetch? || followed_by_local_accounts? || requested_through_relay? || reblog_of_local_status?
  end

  def requested_through_relay?
    super || Relay.find_by(inbox_url: @account.inbox_url)&.enabled?
  end

  def reblog_of_local_status?
    ActivityPub::TagManager.instance.local_uri?(object_uri) && status_from_uri(object_uri)&.account&.local?
  end
end
