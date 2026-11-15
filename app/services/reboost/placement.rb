# frozen_string_literal: true

module Reboost
  COOLDOWN_SECONDS = 300 unless const_defined?(:COOLDOWN_SECONDS, false)
  FEDERATION_GAP = 10.seconds unless const_defined?(:FEDERATION_GAP, false)
end

class Reboost::Placement
  include Payloadable
  include Redisable
  include Lockable

  IDEMPOTENCY_TTL = 3600

  def initialize(account, original, options = {})
    @account = account
    @original = original
    @options = options
  end

  def call
    duplicate = idempotent_result
    return duplicate if duplicate

    with_redis_lock(lock_name) do
      place!
    end
  end

  def self.resume!(operation)
    return if operation.nil? || operation.terminal?

    account = operation.account
    original = Status.find_by(id: operation.reblog_of_id)
    if original.nil?
      operation.fail!('missing_status')
      return
    end

    options = (operation.options || {}).symbolize_keys.merge(
      reboost: operation.reboost,
      idempotency: operation.idempotency_key,
      visibility: operation.visibility,
      circle_id: operation.circle_id,
      resumed_operation_id: operation.id
    )
    new(account, original, options).call
  end

  private

  attr_reader :account, :original, :options

  def place!
    if options[:reboost] && !reboost_allowed?
      raise Mastodon::ReboostDisabledError, I18n.t('statuses.errors.reboost_disabled')
    end

    existing = account.statuses.find_by(reblog: original)
    return finish_idempotent(existing) if existing && !options[:reboost]

    visibility = resolved_visibility(existing)
    @resolved_circle = options[:circle]
    @resolved_circle ||= account.owned_circles.find_by(id: options[:circle_id]) if @resolved_circle.nil? && options[:circle_id].present?
    if visibility == 'mutual'
      visibility = 'limited'
      @resolved_circle ||= account
    end
    ensure_visibility!(visibility)
    audience = inherited_audience(existing)

    creating_new = existing.nil? || options[:reboost]
    if creating_new && cooling_down?
      Reboost::Log.emit('cooldown_rejected', account_id: account.id, status_id: original.id, retry_after: remaining_seconds)
      raise Mastodon::ReboostCooldownError.new(remaining_seconds)
    end

    discarded = discarded_reblog
    if existing.nil? && discarded
      raise_pending!(discarded, visibility) unless finish_removal!(discarded)
    end

    if existing
      begin
        retire!(existing)
      rescue Mastodon::RaceConditionError
        raise_pending!(existing, visibility)
      end
    end

    # Destroy updated the counter on a fresh copy. Drop the stale stat on the
    # original this request is still holding so the new boost increments the
    # row the removal just wrote.
    original.association(:status_stat).reset
    created = create_reblog!(visibility, audience)
    ReboostCooldown.stamp!(account.id, original.id)
    remember_idempotency!(created)
    distribute_locally!(created, federate: existing.nil?)
    schedule_federation!(existing, created) if existing&.local?
    Reboost::Log.emit('replaced', account_id: account.id, status_id: original.id, old_status_id: existing&.id, new_status_id: created.id) if existing
    created
  rescue Mastodon::ReboostPendingError
    raise
  rescue ActiveRecord::RecordInvalid, Mastodon::ValidationError => error
    ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      old_status_id: existing&.id,
      state: 'failed',
      error_code: 'create_failed',
      reboost: !!options[:reboost],
      completed_at: Time.current
    )
    Reboost::Log.emit('failed', account_id: account.id, status_id: original.id, error: error.class)
    raise
  end

  def reboost_allowed?
    account.user&.reboost_enabled?
  end

  def resolved_visibility(existing)
    return original.visibility if original.hidden?
    return existing.visibility if options[:reboost] && existing && !options[:visibility_explicit]

    options[:visibility] || account.user&.setting_default_privacy || ('public' if account.local? && account.group?)
  end

  def ensure_visibility!(visibility)
    ExternalBridge::Visibility.reject_composable!(visibility)
    prohibited = account.user&.setting_prohibited_visibilities&.filter(&:present?)
    return unless prohibited&.include?(visibility) || visibility == 'personal'

    raise Mastodon::ValidationError, I18n.t('status_prohibit.validations.prohibited_visibilities')
  end

  def cooling_down?
    remaining_seconds.positive?
  end

  def remaining_seconds
    @remaining_seconds ||= ReboostCooldown.remaining_seconds(account.id, original.id)
  end

  def discarded_reblog
    Status.unscoped.where(account_id: account.id, reblog_of_id: original.id).where.not(deleted_at: nil).order(id: :desc).first
  end

  def finish_removal!(discarded)
    RemoveStatusService.new.call(discarded, skip_remote: true, immediate: true)
    true
  rescue Mastodon::RaceConditionError
    false
  end

  def raise_pending!(discarded, visibility)
    operation = ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      old_status_id: discarded.id,
      state: 'pending',
      visibility: visibility,
      circle_id: @resolved_circle&.id || options[:circle_id],
      idempotency_key: options[:idempotency],
      reboost: !!options[:reboost],
      options: {
        'visibility_explicit' => !!options[:visibility_explicit],
        'circle_explicit' => !!options[:circle_explicit],
      }
    )
    remember_idempotency!(operation)
    Reboost::ResumeWorker.perform_in(2.seconds, operation.id)
    Reboost::Log.emit('pending', operation_id: operation.id, account_id: account.id, status_id: original.id)
    raise Mastodon::ReboostPendingError, operation
  end

  def retire!(existing)
    return if existing.nil?

    started = Time.current
    suppress_late_announce!(existing)
    snapshot_undo!(existing)
    if existing.reported?
      RemoveStatusService.new.call(existing, skip_remote: true, preserve: true)
      original.decrement_count!(:reblogs_count)
    else
      RemoveStatusService.new.call(existing, skip_remote: true, immediate: true)
    end
    Reboost::Log.emit(
      'removed',
      account_id: account.id,
      status_id: original.id,
      old_status_id: existing.id,
      milliseconds: ((Time.current - started) * 1000).round
    )
  end

  def inherited_audience(existing)
    return [] unless options[:reboost] && existing && !options[:visibility_explicit] && !options[:circle_explicit]

    existing.mentions.pluck(:account_id, :silent)
  end

  def create_reblog!(visibility, audience)
    reblog = nil
    circle = @resolved_circle
    ApplicationRecord.transaction do
      reblog = account.statuses.create!(reblog: original, text: '', visibility: visibility, rate_limit: options[:with_rate_limit])
      reblog.capability_tokens.create! if reblog.limited_visibility?
    end
    ProcessMentionsService.new.call(reblog, circle)
    audience.each do |account_id, silent|
      reblog.mentions.find_or_create_by!(account_id: account_id) { |copy| copy.silent = silent }
    end
    reblog
  end

  def distribute_locally!(reblog, federate:)
    DistributionWorker.perform_async(reblog.id)
    ActivityPub::DistributionWorker.perform_async(reblog.id) if federate
    return if reblog.account.group?

    LocalNotificationWorker.perform_async(original.account_id, reblog.id, reblog.class.name, 'reblog') if original.account.local?
    ActivityTracker.increment('activity:interactions')
    PotentialFriendshipTracker.record(account.id, original.account_id, :reblog) unless account.following?(original.account_id)
    record_use!(reblog)
    Trends.register!(reblog)
  end

  def record_use!(reblog)
    return unless reblog.public_visibility?

    original.tags.each { |tag| tag.use!(account) }
  end

  def schedule_federation!(previous, created)
    return unless previous&.local? && created.local?

    operation = ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      old_status_id: previous.id,
      new_status_id: created.id,
      state: 'federating',
      reboost: true,
      undo_payload: @undo_payload,
      undo_inboxes: @undo_inboxes || [],
      removal_finished_at: Time.current
    )
    Reboost::FederationWorker.perform_in(Reboost::FEDERATION_GAP, operation.id)
    Reboost::Log.emit('federation_scheduled', operation_id: operation.id, gap_seconds: Reboost::FEDERATION_GAP.to_i)
  end

  def suppress_late_announce!(status)
    RedisConfiguration.with do |redis|
      redis.setex("reboost:suppress_announce:#{status.id}", 6.hours.to_i, '1')
    end
  end

  def snapshot_undo!(status)
    @retired_id = status.id
    return unless status.local?

    @undo_inboxes = StatusReachFinder.new(status, unsafe: true).inboxes
    @undo_payload = Oj.dump(serialize_payload(status, ActivityPub::UndoAnnounceSerializer, signer: status.account))
  end

  def finish_idempotent(status)
    remember_idempotency!(status)
    status
  end

  def idempotent_result
    key = options[:idempotency].presence
    return if key.blank?

    cached = RedisConfiguration.with { |redis| redis.get(idempotency_key(key)) }
    return if cached.blank?

    if cached.start_with?('status:')
      Status.find_by(id: cached.delete_prefix('status:'))
    elsif cached.start_with?('operation:')
      operation = ReboostOperation.find_by(id: cached.delete_prefix('operation:'))
      raise Mastodon::ReboostPendingError, operation if operation && !operation.terminal?

      operation&.new_status_id && Status.find_by(id: operation.new_status_id)
    end
  end

  def remember_idempotency!(record)
    key = options[:idempotency].presence
    return if key.blank? || record.nil?

    value = record.is_a?(ReboostOperation) ? "operation:#{record.id}" : "status:#{record.id}"
    RedisConfiguration.with { |redis| redis.setex(idempotency_key(key), IDEMPOTENCY_TTL, value) }
  end

  def idempotency_key(key)
    "idempotency:reboost:#{account.id}:#{key}"
  end

  def lock_name
    "reboost:#{account.id}:#{original.id}"
  end
end
