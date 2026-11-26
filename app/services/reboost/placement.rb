# frozen_string_literal: true

module Reboost
  COOLDOWN_SECONDS = 300 unless const_defined?(:COOLDOWN_SECONDS, false)
  FEDERATION_GAP = 10.seconds unless const_defined?(:FEDERATION_GAP, false)
end

class Reboost::Placement
  include Payloadable
  include Redisable
  include Lockable
  include Reboost::FederationSchedule
  include Reboost::CreatedBoost

  IDEMPOTENCY_TTL = 3600

  def initialize(account, original, options = {})
    @account = account
    @original = original
    @options = options
  end

  def call
    duplicate = idempotent_result
    return duplicate if duplicate

    begin
      with_redis_lock(lock_name) do
        duplicate = idempotent_result
        return duplicate if duplicate

        place!
      end
    ensure
      enqueue_deferred_resume!
    end
  end

  def self.fail_open!(operation, code)
    Reboost::PendingTransition.fail!(operation, code)
  end

  def self.cancel_pending!(account, status_id)
    new(account, nil, lock_status_id: status_id).cancel_pending!
  end

  def cancel_pending!
    with_redis_lock(lock_name) do
      now = Time.current
      ReboostOperation.where(account_id: account.id, reblog_of_id: options[:lock_status_id], state: 'pending').find_each do |operation|
        operation.update!({
          state: 'cancelled',
          error_code: 'unreblogged',
          completed_at: now,
        }.merge(Reboost::UndoDelivery.terminal_undo_attributes(operation)))
        Reboost::UndoDelivery.enqueue!(operation)
      end
    end
  end

  def self.resume!(operation)
    return if operation.nil?

    operation.reload
    return if operation.terminal?

    if operation.state == 'federating'
      Reboost::DeliveryResume.resume!(operation)
      return Status.find_by(id: operation.new_status_id)
    end
    return unless operation.state == 'pending'

    account = operation.account
    original = Status.find_by(id: operation.reblog_of_id)
    if original.nil?
      fail_open!(operation, 'missing_status')
      return
    end

    unless StatusPolicy.new(account, original).reblog?
      fail_open!(operation, 'not_permitted')
      return
    end

    options = (operation.options || {}).symbolize_keys.merge(
      reboost: operation.reboost,
      idempotency: operation.idempotency_key,
      visibility: operation.visibility,
      circle_id: operation.circle_id,
      resumed_operation_id: operation.id
    )
    result = new(account, original, options).call
    return if result.nil?

    operation.reload
    return result if operation.terminal? || operation.state == 'federating'

    operation.update!(state: 'completed', new_status_id: result.id, completed_at: Time.current)
    result
  end

  private

  attr_reader :account, :original, :options

  def place!
    gate = Reboost::PendingTransition.resumed_result(resumed_operation)
    return gate if gate.is_a?(Status)
    return if gate != :continue
    return if resumed_cancelled?

    linked = resume_unlinked_wrapper!
    return linked if linked

    joined = Reboost::OpenOperation.join!(account: account, original_id: original.id, resumed_operation_id: options[:resumed_operation_id])
    return ensure_joined!(joined) if joined

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
    # [] is a decided empty audience. nil means this pass has no snapshot.
    audience = saved_audience if saved_audience.is_a?(Array) && audience.blank?

    creating_new = existing.nil? || options[:reboost]
    if creating_new && cooling_down?
      Reboost::Log.emit('cooldown_rejected', account_id: account.id, status_id: original.id, retry_after: remaining_seconds)
      raise Mastodon::ReboostCooldownError, remaining_seconds
    end

    clear_previous!(existing, discarded_reblog, visibility, audience)
    return if resumed_cancelled?

    # Destroy updated the counter on a fresh copy. Drop the stale stat on the
    # original this request is still holding so the new boost increments the
    # row the removal just wrote.
    original.association(:status_stat).reset
    # Status, audience, cooldown, and the operation link commit together.
    # Redis and queues run only after that commit.
    created = create_reblog!(visibility, audience, existing)
    remember_idempotency!(created)
    publish_created!(created, existing)
    Reboost::Log.emit('replaced', account_id: account.id, status_id: original.id, old_status_id: existing&.id, new_status_id: created.id) if existing
    created
  rescue Mastodon::ReboostPendingError
    raise
  rescue ActiveRecord::RecordInvalid, Mastodon::ValidationError => e
    recover_failed_create!(existing, e)
    raise
  end

  def clear_previous!(existing, discarded, visibility, audience)
    if existing.nil? && discarded
      snapshot_undo!(discarded)
      raise_pending!(discarded, visibility, inherited_audience(discarded)) unless finish_removal!(discarded)
    elsif existing
      begin
        retire!(existing, visibility, audience)
      rescue Mastodon::RaceConditionError
        raise_pending!(existing, visibility, audience)
      end
    end
  end

  def ensure_joined!(status)
    ensure_federating!(status)
    status
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
    if discarded.reported?
      RemoveStatusService.new.call(discarded, skip_remote: true, preserve: true)
      decrement_retained_once!(discarded)
    else
      RemoveStatusService.new.call(discarded, skip_remote: true, immediate: true)
    end
    true
  rescue Mastodon::RaceConditionError
    false
  end

  def decrement_retained_once!(status)
    Reboost::RetainedCount.release!(original, status)
  end

  def raise_pending!(discarded, visibility, audience = nil)
    operation = @recovery || resumed_operation || ReboostOperation.new
    operation.assign_attributes(
      account: account,
      reblog_of_id: original.id,
      old_status_id: discarded.id,
      state: 'pending',
      visibility: visibility,
      circle_id: @resolved_circle&.id || options[:circle_id],
      idempotency_key: options[:idempotency],
      reboost: options[:reboost] == true,
      undo_payload: @undo_payload,
      undo_inboxes: @undo_inboxes || [],
      options: {
        'visibility_explicit' => options[:visibility_explicit] == true,
        'circle_explicit' => options[:circle_explicit] == true,
        'audience' => Reboost::RecoveryRecord.audience_for(audience, operation.options, @resolved_circle, discarded, options),
      }
    )
    Reboost::OpenOperation.save!(operation)
    @recovery = operation
    remember_idempotency!(operation)
    @deferred_resume_id = operation.id
    Reboost::Log.emit('pending', operation_id: operation.id, account_id: account.id, status_id: original.id)
    raise Mastodon::ReboostPendingError, operation
  end

  def retire!(existing, visibility = nil, audience = nil)
    return if existing.nil?

    started = Time.current
    suppress_late_announce!(existing)
    snapshot_undo!(existing)
    persist_recovery!(existing, visibility, audience) if existing.local?
    if existing.reported?
      RemoveStatusService.new.call(existing, skip_remote: true, preserve: true)
      decrement_retained_once!(existing)
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

  def create_reblog!(visibility, audience, existing = nil)
    commit_created_boost!(visibility, audience, existing)
  end

  def distribute_locally!(reblog, federate:, operation: nil)
    if operation
      Reboost::DeliveryResume.new.enqueue_home!(operation, reblog)
      Reboost::DeliveryResume.new.enqueue_notification!(operation, reblog)
    else
      DistributionWorker.perform_async(reblog.id)
    end
    ActivityPub::DistributionWorker.perform_async(reblog.id) if federate
    return if reblog.account.group?

    LocalNotificationWorker.perform_async(original.account_id, reblog.id, reblog.class.name, 'reblog') if operation.nil? && original.account.local?
    ActivityTracker.increment('activity:interactions')
    PotentialFriendshipTracker.record(account.id, original.account_id, :reblog) unless account.following?(original.account_id)
    record_use!(reblog)
    Trends.register!(reblog)
  end

  def record_use!(reblog)
    return unless reblog.public_visibility?

    original.tags.each { |tag| tag.use!(account) }
  end

  def federation_operation(created, previous)
    operation = @recovery || resumed_operation || ReboostOperation.new
    operation.assign_attributes(
      account: account,
      reblog_of_id: original.id,
      old_status_id: previous&.id || operation.old_status_id || @retired_id,
      new_status_id: created.id,
      state: 'federating',
      reboost: true,
      undo_payload: @undo_payload.presence || operation.undo_payload,
      undo_inboxes: @undo_inboxes.nil? ? Array(operation.undo_inboxes) : @undo_inboxes,
      removal_finished_at: Time.current
    )
    operation.save!
    @recovery = operation
    operation
  end

  def persist_recovery!(existing, visibility, audience)
    @recovery = Reboost::RecoveryRecord.save!(
      existing: existing,
      operation: resumed_operation,
      account: account,
      original: original,
      visibility: visibility,
      circle: @resolved_circle,
      audience: audience,
      options: options,
      undo_payload: @undo_payload,
      undo_inboxes: @undo_inboxes || []
    )
  end

  def recover_failed_create!(existing, error)
    operation = failed_create_operation!(existing)
    begin
      # The row is already terminal. A raised enqueue stays on that row for the scheduler.
      Reboost::UndoDelivery.enqueue!(operation)
    rescue StandardError
      nil
    end
    Reboost::Log.emit('failed', account_id: account.id, status_id: original.id, error: error.class)
  end

  # Create failure closes this operation. It does not open a second failed row,
  # and it does not stay federating where the scheduler cannot see it.
  def failed_create_operation!(existing)
    operation = @recovery || resumed_operation
    attributes = {
      state: 'failed',
      error_code: 'create_failed',
      completed_at: Time.current,
      old_status_id: operation&.old_status_id || existing&.id || @retired_id,
    }
    if operation
      operation.reload
      operation.update!(attributes.merge(Reboost::UndoDelivery.terminal_undo_attributes(operation)))
      operation
    else
      created = ReboostOperation.create!(
        attributes.merge(
          account: account,
          reblog_of_id: original.id,
          reboost: options[:reboost] == true,
          undo_payload: @undo_payload,
          undo_inboxes: @undo_inboxes || []
        )
      )
      created.update!(Reboost::UndoDelivery.terminal_undo_attributes(created))
      created
    end
  end

  def ordered_undo?
    @undo_payload.present? || resumed_operation&.undo_payload.present?
  end

  def saved_audience
    pairs = resumed_operation&.options&.[]('audience')
    return unless pairs.is_a?(Array)

    pairs.map { |account_id, silent| [account_id.to_i, silent == true] }
  end

  def resumed_operation
    return if options[:resumed_operation_id].blank?

    @resumed_operation ||= ReboostOperation.find_by(id: options[:resumed_operation_id])
  end

  def resumed_cancelled?
    op = resumed_operation
    return false if op.nil?

    op.reload.terminal?
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
      status = Status.find_by(id: cached.delete_prefix('status:'))
      ensure_federating!(status)
      status
    elsif cached.start_with?('operation:')
      operation = ReboostOperation.find_by(id: cached.delete_prefix('operation:'))
      if operation && !operation.terminal?
        # The resume of this same row must not treat its own cache entry as a duplicate.
        return if options[:resumed_operation_id].to_s == operation.id.to_s

        raise Mastodon::ReboostPendingError, operation
      end

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
    "reboost:#{account.id}:#{options[:lock_status_id] || original.id}"
  end

  # Sidekiq inline runs the worker immediately. Queue it only after this
  # request has released the placement lock.
  def enqueue_deferred_resume!
    operation_id = @deferred_resume_id
    return if operation_id.nil?

    @deferred_resume_id = nil
    Reboost::ResumeWorker.perform_in(2.seconds, operation_id)
  end
end
