# frozen_string_literal: true

class ActivityPub::Activity::Announce < ActivityPub::Activity
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

    remaining = ReboostCooldown.remaining_seconds(@account.id, @original_status.id)
    if remaining.positive?
      hold_newer_announce!(parsed_published)
      return
    end

    accept_new_announce!
  end

  def accept_new_announce!
    process_status
    remember_current_announce!
    ReboostCooldown.stamp!(@account.id, @original_status.id)
  end

  def receive_another_announce!
    return postprocess_audience_and_deliver if @status.uri == @json['id'] && @options[:delivered_to_account_id].present?
    return if @status.uri == @json['id']

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

    replace_announce!
  rescue Mastodon::RaceConditionError
    hold_newer_announce!(parsed_published)
  end

  def replace_announce!
    previous = @status
    ReboostAnnounceState.supersede!(@account.id, previous.uri, reblog_of_id: @original_status.id) if previous.uri.present?
    finish_discarded!(previous)
    @original_status.association(:status_stat).reset
    @status = nil
    accept_new_announce!
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

  def hold_newer_announce!(published)
    available_at = Time.current + ReboostCooldown.remaining_seconds(@account.id, @original_status.id).seconds
    RemoteReboostHold.store!(
      @account.id,
      @original_status.id,
      @json['id'],
      published,
      @json.is_a?(Hash) ? @json.deep_stringify_keys : {},
      available_at
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
    distribute(@status)
    expire_queue_action
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
