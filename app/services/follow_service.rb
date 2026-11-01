# frozen_string_literal: true

class FollowService < BaseService
  include Redisable
  include Payloadable
  include DomainControlHelper

  # Follow a remote user, notify remote user about the follow
  # @param [Account] source_account From which to follow
  # @param [Account] target_account Account to follow
  # @param [Hash] options
  # @option [Boolean] :reblogs Whether or not to show reblogs, defaults to true
  # @option [Boolean] :notify_reblogs Whether to notify about boosts, defaults to false
  # @option [Boolean] :notify Whether to create notifications about new posts, defaults to false
  # @option [Array<String>] :languages Which languages to allow on the home feed from this account, defaults to all
  # @option [Boolean] :bypass_locked
  # @option [Boolean] :bypass_limit Allow following past the total follow number
  # @option [Boolean] :with_rate_limit
  # @option [Boolean] :delivery
  # @option [Boolean] :defer_distribution Keep Sidekiq, notifications, and
  #   Redis outside this call. The follow row is still created here. The
  #   caller commits, then calls flush_distribution!. A rolled-back follow
  #   therefore has no delivery job. Ordinary follows leave this unset.
  def call(source_account, target_account, options = {})
    @source_account = source_account
    @target_account = target_account
    @options        = { bypass_locked: false, delivery: true, bypass_limit: false, with_rate_limit: false }.merge(options)

    if options[:tracking_moved_account]
      while @target_account.moved?
        raise ActiveRecord::RecordNotFound if following_not_possible?
        raise Mastodon::NotPermittedError  if following_not_allowed_without_move?

        @target_account = Account.find(@target_account.moved_to_account_id)
      end
    end

    raise ActiveRecord::RecordNotFound if following_not_possible?
    raise Mastodon::NotPermittedError  if following_not_allowed?

    if @source_account.following?(@target_account)
      follow = change_follow_options!
      # The batch executor already claimed this follow-import target to queued,
      # but this early return runs neither the local NEW-follow settlement nor
      # remote delivery tracking. Settle it here so it does not sit queued forever.
      settle_follow_import_target(follow)
      return follow
    elsif @source_account.requested?(@target_account)
      request = change_follow_request_options!
      settle_follow_import_target(request)
      return request
    end

    if defer_distribution?
      @deferred_activity = true
      @deferred_home_partial = @source_account.not_following_anyone?
    else
      ActivityTracker.increment('activity:interactions')

      # When an account follows someone for the first time, avoid showing
      # an empty home feed while the follow request is being processed
      # and the feeds are being merged
      mark_home_feed_as_partial! if @source_account.not_following_anyone?
    end

    follow = if follow_request_required?
               request_follow!
             elsif @target_account.local?
               direct_follow!
             end

    if follow
      Moderation::EventRecorder.record_interaction(
        actor: @source_account,
        target: @target_account,
        event_type: :follow,
        source_record: follow,
        source_event_key: follow_source_event_key(follow),
        # Only set for follows executed by a follow import; the import passes the
        # FollowImportBatch id explicitly through :import_batch_id. Normal UI /
        # API / ActivityPub follows leave it nil, so the ledger column stays NULL.
        import_batch_id: @options[:import_batch_id]
      )

      # Shadow observation only (off by default, failure-tolerant, async): records
      # what friction the adaptive follow gate WOULD propose. It never alters this
      # follow. A deferred follow enqueues it with the other distribution.
      if defer_distribution?
        if Moderation::FollowGateShadowObserver.enabled?
          @deferred_shadow = {
            source_account: @source_account,
            target_account: @target_account,
            mechanism: shadow_follow_mechanism,
            target_locked: @target_account.locked?,
            attempted_at: Time.now.utc,
          }
        end
      else
        Moderation::FollowGateShadowObserver.observe(
          source_account: @source_account,
          target_account: @target_account,
          mechanism: shadow_follow_mechanism
        )
      end

      # Drive the execution state of a LOCAL follow-import target to a reachable
      # terminal (remote targets are tracked inside request_follow! via delivery
      # tracking + inbound Accept/Reject).
      track_local_follow_import_target(follow)
    end

    follow
  end

  # Runs the Redis and Sidekiq work skipped by defer_distribution. Call this
  # only after the follow transaction has committed. Each step is marked
  # done after it succeeds, so a later call on this same instance continues
  # the remaining steps and does not repeat a finished one. A deleted follow
  # is skipped instead of raising.
  #
  # With defer_distribution, non-database work is only the list below.
  # Database writes (the follow row, its counters, follow-import bookkeeping,
  # and the moderation interaction) stay in the caller's transaction and roll
  # back with it. The follow rate-limit Redis key is recorded on create and
  # removed by Follow's after_rollback.
  #
  # Deferred, then sent here: LocalNotificationWorker, MergeWorker,
  # UnmergeWorker, ActivityPub::DeliveryWorker, NotifyService, the interaction
  # counter, the empty-home Redis hint, and the shadow follow-gate job.
  # distribute_persisted! is the cross-process fallback. The founding-follow
  # obligation stores whether the empty-home hint was needed before inserting
  # its relationship, and passes that along with its original attempt time.
  # Jobs are at-least-once if a process dies between enqueue and the durable
  # distribution marker. A persisted "followed" notification is redelivered
  # using the same DB row: a prior crash after saving it but before Push must
  # not silently drop that Push. External Push/email may still be repeated.
  # Follow imports do not use this path.
  def deferred_home_partial?
    @deferred_home_partial == true
  end

  # Capture what was observable at Follow creation. The current shadow flag
  # remains a kill switch if it is disabled before a deferred send.
  def deferred_shadow_snapshot
    @deferred_shadow
  end

  def flush_distribution!
    # MergeWorker clears the regeneration hint in ensure. Set the hint before
    # enqueuing Merge, otherwise a fast worker may clear it and we may recreate
    # a stale, day-long marker after the merge is finished.
    flush_deferred_home!
    flush_deferred_jobs!
    flush_deferred_notices!
    flush_deferred_activity!
    flush_deferred_shadow!
  end

  def flush_deferred_jobs!
    @deferred_job_index ||= 0
    while @deferred_job_index < deferred_distribution.length
      worker, args = deferred_distribution[@deferred_job_index]
      worker.perform_async(*args)
      @deferred_job_index += 1
    end
  end

  def flush_deferred_notices!
    @deferred_notice_index ||= 0
    notices = Array(@deferred_notices)
    while @deferred_notice_index < notices.length
      account_id, type, record_class, record_id = notices[@deferred_notice_index]
      record = record_class.constantize.find_by(id: record_id)
      NotifyService.new.call(Account.find(account_id), type, record) if record
      @deferred_notice_index += 1
    end
  end

  def flush_deferred_activity!
    return if @deferred_activity_flushed || !@deferred_activity

    ActivityTracker.increment('activity:interactions')
    @deferred_activity_flushed = true
  end

  def flush_deferred_home!
    return if @deferred_home_flushed || !@deferred_home_partial

    mark_home_feed_as_partial!
    @deferred_home_flushed = true
  end

  def flush_deferred_shadow!
    return if @deferred_shadow_flushed || @deferred_shadow.nil?

    Moderation::FollowGateShadowObserver.observe(**@deferred_shadow)
    @deferred_shadow_flushed = true
  end

  # Distribution for a follow that was committed by an earlier process.
  # Used when that process died before flush_distribution!.
  def self.distribute_persisted!(record, home_feed_partial_required: false, attempted_at: nil, shadow_observation_required: false, shadow_target_locked: false)
    return if record.nil?

    new.distribute_persisted!(
      record,
      home_feed_partial_required: home_feed_partial_required,
      attempted_at: attempted_at,
      shadow_observation_required: shadow_observation_required,
      shadow_target_locked: shadow_target_locked
    )
  end

  def distribute_persisted!(record, home_feed_partial_required: false, attempted_at: nil, shadow_observation_required: false, shadow_target_locked: false)
    source = record.account
    target = record.target_account

    # MergeWorker deletes this hint after the merge. Queueing it first can
    # leave a stale Redis hint if Merge finishes before this line executes.
    if home_feed_partial_required
      @source_account = source
      mark_home_feed_as_partial!
    end

    if record.is_a?(Follow)
      LocalNotificationWorker.perform_async(target.id, record.id, record.class.name, 'follow')
      if source.local?
        existing = Notification.find_by(account_id: source.id, activity_type: record.class.name, activity_id: record.id, type: 'followed')
        if existing
          # The row might have committed before the previous process crashed
          # while sending Push. Resend that *same* row rather than skipping.
          NotifyService.new.redeliver_existing!(existing)
        else
          NotifyService.new.call(source, 'followed', record)
        end
      end
      MergeWorker.perform_async(target.id, source.id) if record.delivery?
    elsif target.local?
      LocalNotificationWorker.perform_async(target.id, record.id, record.class.name, 'follow_request')
    elsif target.activitypub? && source.local?
      ActivityPub::DeliveryWorker.perform_async(build_json(record), source.id, target.inbox_url, { 'bypass_availability' => true })
    end

    ActivityTracker.increment('activity:interactions')
    if shadow_observation_required
      Moderation::FollowGateShadowObserver.observe(
        source_account: source,
        target_account: target,
        mechanism: nil,
        target_locked: shadow_target_locked,
        attempted_at: attempted_at
      )
    end
  end

  private

  # Key the outbound follow interaction on the ActivityPub Follow activity
  # identity (the follow record's uri) in a *direction-specific* namespace, so an
  # inbound follow-request Reject can correlate back to it after reject! has
  # destroyed the FollowRequest. A dedicated outbound namespace keeps these local
  # anchors from ever colliding with inbound follow ids (which are supplied by
  # remote actors and keyed activitypub_follow:<id> in activity/follow.rb). Falls
  # back to the record-derived key when no uri is present.
  def follow_source_event_key(follow)
    uri = follow.try(:uri)
    "activitypub_outbound_follow:#{uri}" if uri.present?
  end

  # Behaviour-neutral attempt mechanism for the shadow follow-gate observation
  # (echoed, never used to raise risk). Derived from existing options.
  def shadow_follow_mechanism
    return 'follow_import' if @options[:import_batch_id].present?
    return 'migration' if @options[:tracking_moved_account]

    nil
  end

  def mark_home_feed_as_partial!
    redis.set("account:#{@source_account.id}:regeneration", true, nx: true, ex: 1.day.seconds)
  end

  # Locked accounts, silenced sources, and remote ActivityPub targets still
  # become follow requests. A bot follow of a Person keeps that Person's
  # confirm-from-bot setting. A group has no login: an unlocked group
  # accepts the follow, and a locked group stays a request.
  def follow_request_required?
    return true if @source_account.silenced? || @target_account.activitypub?
    return false if @options[:bypass_locked]

    @target_account.locked? || bot_follow_needs_confirmation?
  end

  def bot_follow_needs_confirmation?
    return false unless @source_account.bot? && @target_account.local?
    return false if @target_account.group?

    @target_account.user&.setting_confirm_follow_from_bot
  end

  def following_not_possible?
    @target_account.nil? || @target_account.id == @source_account.id || @target_account.suspended?
  end

  def following_not_allowed?
    following_not_allowed_without_move? || @target_account.moved? || target_domain_following_not_allowed_from_new_account?
  end

  def following_not_allowed_without_move?
    domain_not_allowed?(@target_account.domain) || @target_account.blocking?(@source_account) || @source_account.blocking?(@target_account) || (!@target_account.local? && @target_account.ostatus?) || @source_account.domain_blocking?(@target_account.domain)
  end

  # Domains that new accounts (created within 2 weeks) are not allowed to follow.
  # This value is configured in `config.x.not_allowed_from_new_accounts` via an
  # initializer (populated from `ENV['NOT_ALLOWED_FROM_NEW_ACCOUNTS']`).
  # Defaults to an empty array.
  def not_allowed_from_new_accounts
    Rails.application.config.x.not_allowed_from_new_accounts || []
  end

  def target_domain_following_not_allowed_from_new_account?
    not_allowed_from_new_accounts.include?(@target_account.domain&.downcase) && @source_account.created_at > 2.weeks.ago
  end

  def change_follow_options!
    if !@source_account.delivery_following?(@target_account) && @options[:delivery]
      enqueue_distribution(MergeWorker, @target_account.id, @source_account.id)
    elsif @source_account.delivery_following?(@target_account) && @options[:delivery] == false
      enqueue_distribution(UnmergeWorker, @target_account.id, @source_account.id)
    end
    @source_account.follow!(@target_account, reblogs: @options[:reblogs], notify: @options[:notify], notify_reblogs: @options[:notify_reblogs], delivery: @options[:delivery], languages: @options[:languages])
  end

  def change_follow_request_options!
    @source_account.request_follow!(@target_account, reblogs: @options[:reblogs], notify: @options[:notify], notify_reblogs: @options[:notify_reblogs], delivery: @options[:delivery], languages: @options[:languages])
  end

  def request_follow!
    follow_request = @source_account.request_follow!(@target_account, reblogs: @options[:reblogs], notify: @options[:notify], notify_reblogs: @options[:notify_reblogs], delivery: @options[:delivery], languages: @options[:languages], rate_limit: @options[:with_rate_limit], bypass_limit: @options[:bypass_limit])

    if @target_account.local?
      enqueue_distribution(LocalNotificationWorker, @target_account.id, follow_request.id, follow_request.class.name, 'follow_request')
    elsif @target_account.activitypub?
      delivery_options = { 'bypass_availability' => true }
      # Persist the target's correlation URI + queued state BEFORE enqueuing the
      # Follow for delivery, and attach opaque tracking metadata so delivery
      # success/failure updates the target. Only set for follow-import follows;
      # normal follows leave delivery_options untouched.
      tracking = prepare_follow_import_tracking(follow_request)
      if tracking
        # Stamp enqueue time at the last moment before perform_async so
        # Follow Import delivery telemetry can measure push-queue wait.
        # Ordinary (non-import) follows never set delivery_tracking.
        tracking = tracking.merge('enqueued_at' => Time.now.utc.iso8601(6))
        delivery_options['delivery_tracking'] = tracking
      end

      enqueue_distribution(ActivityPub::DeliveryWorker, build_json(follow_request), @source_account.id, @target_account.inbox_url, delivery_options)
    end

    follow_request
  end

  # Locate the follow-import target this follow executes (when the import passes
  # its batch id), persist follow_request_uri + queued on it, and return the
  # opaque delivery-tracking metadata. Failure-tolerant: tracking setup must
  # never break the follow itself.
  def prepare_follow_import_tracking(follow_request)
    target = resolve_follow_import_target
    return nil if target.nil?

    # A target that was unresolved at record time (no subject yet) is backfilled
    # now that this execution resolved the account, so its ledger link is exact.
    backfill_follow_import_target_subject(target)

    # Persist the durable correlation URI independently of the state transition:
    # the controlled executor may have ALREADY claimed this target (pending ->
    # queued) before enqueuing us, in which case a queued -> queued transition is
    # a no-op and could not carry the uri. The uri must still be persisted before
    # delivery is enqueued so an inbound Accept/Reject can correlate.
    persist_follow_request_uri(target, follow_request.uri)
    FollowImport::TargetTransitionService.new.mark_queued(target)

    { 'type' => 'follow_import_target', 'id' => target.id }
  rescue StandardError => e
    Rails.logger.warn("[FollowService] follow-import delivery tracking setup failed: #{e.class}: #{e.message}")
    nil
  end

  # Prefer the exact target id propagated from the import (robust for targets
  # that were unresolved at record time). Fall back to batch + resolved subject
  # for callers that only pass a batch id.
  def resolve_follow_import_target
    target_id = @options[:follow_import_target_id]

    if target_id.present?
      target = FollowImportTarget.find_by(id: target_id)
      batch_id = @options[:import_batch_id]
      # Fail closed on an inconsistent (id, batch) pair rather than tracking the
      # wrong batch's target.
      return nil if target && batch_id.present? && target.batch_id != batch_id.to_i

      return target
    end

    batch_id = @options[:import_batch_id]
    return nil if batch_id.blank?

    subject = ModerationSubject.find_by(account_id: @target_account.id)
    return nil if subject.nil?

    FollowImportTarget.find_by(batch_id: batch_id, target_subject_id: subject.id)
  end

  def backfill_follow_import_target_subject(target)
    return if target.target_subject_id.present?

    subject = ModerationSubject.for_account!(@target_account)
    target.update!(target_subject_id: subject.id)
  rescue StandardError => e
    # Best-effort: correlation still works via the target id, so a backfill
    # failure must not abort tracking of this follow.
    Rails.logger.warn("[FollowService] follow-import target subject backfill failed: #{e.class}: #{e.message}")
  end

  def persist_follow_request_uri(target, uri)
    return if uri.blank? || target.follow_request_uri.present?

    target.update!(follow_request_uri: uri)
  end

  # Settle a NEW local follow-import target. Remote NEW follows are settled by
  # delivery tracking inside request_follow!, so this is local-only here.
  def track_local_follow_import_target(follow)
    return unless @target_account.local?

    settle_follow_import_target(follow)
  end

  # Bring a follow-import target to a reachable execution state when there is no
  # remote delivery round-trip to track it — i.e. a local follow, or an
  # already-existing relationship discovered on the early-return paths. Applies to
  # both local and remote targets:
  #
  #   * an established Follow            -> accepted (terminal).
  #   * a pending FollowRequest          -> awaiting_response, persisting the
  #     request's uri so a later approve/reject (local via AuthorizeFollowService/
  #     RejectFollowService, remote via inbound Accept/Reject) correlates. The
  #     periodic sweeper completes it if no decision ever arrives.
  #
  # Failure-tolerant: never breaks the follow.
  def settle_follow_import_target(record)
    target = resolve_follow_import_target
    return if target.nil?

    backfill_follow_import_target_subject(target)
    transitions = FollowImport::TargetTransitionService.new
    transitions.mark_queued(target)

    if record.is_a?(FollowRequest)
      transitions.mark_awaiting_response(
        target,
        follow_request_uri: record.uri,
        response_deadline_at: FollowImport::ExecutionPolicy.response_deadline_at
      )
    else
      transitions.mark_accepted(target)
    end
  rescue StandardError => e
    Rails.logger.warn("[FollowService] follow-import target settlement failed: #{e.class}: #{e.message}")
  end

  def direct_follow!
    follow = @source_account.follow!(@target_account, reblogs: @options[:reblogs], notify: @options[:notify], notify_reblogs: @options[:notify_reblogs], delivery: @options[:delivery], languages: @options[:languages], rate_limit: @options[:with_rate_limit], bypass_limit: @options[:bypass_limit])

    enqueue_distribution(LocalNotificationWorker, @target_account.id, follow.id, follow.class.name, 'follow')
    if defer_distribution?
      (@deferred_notices ||= []) << [@source_account.id, 'followed', follow.class.name, follow.id]
    else
      NotifyService.new.call(@source_account, 'followed', follow)
    end
    enqueue_distribution(MergeWorker, @target_account.id, @source_account.id) if @options[:delivery]

    follow
  end

  def defer_distribution?
    @options[:defer_distribution]
  end

  def deferred_distribution
    @deferred_distribution ||= []
  end

  def enqueue_distribution(worker, *args)
    if defer_distribution?
      deferred_distribution << [worker, args]
    else
      worker.perform_async(*args)
    end
  end

  def build_json(follow_request)
    Oj.dump(serialize_payload(follow_request, ActivityPub::FollowSerializer))
  end
end
