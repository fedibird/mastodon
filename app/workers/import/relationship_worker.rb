# frozen_string_literal: true

class Import::RelationshipWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8, dead: false

  # Follow-import targets are claimed (queued) before this job runs. If every
  # retry is used after the remote account resolves — and before ActivityPub
  # delivery is reached — nothing else terminalizes them, so they stay queued.
  # Only an explicit follow_import_target_id is settled. Ordinary follow, block,
  # mute, and import jobs are ignored, and a late hook must not overwrite a
  # result that is already terminal. Failure-tolerant.
  sidekiq_retries_exhausted do |msg|
    args         = msg['args'] || []
    relationship = args[2]
    options      = args[3].is_a?(Hash) ? args[3] : {}
    target_id    = options['follow_import_target_id']

    if relationship == 'follow' && target_id.present?
      begin
        ActiveRecord::Base.connection_pool.with_connection do
          target = FollowImportTarget.find_by(id: target_id)

          if target
            FollowImport::TargetTransitionService.new.mark_delivery_failed(
              target,
              failure_code: 'relationship_retries_exhausted'
            )
          end
        end
      rescue StandardError => e
        Rails.logger.warn("[Import::RelationshipWorker] retries-exhausted follow-import terminalization failed: #{e.class}: #{e.message}")
      end
    end
  end

  def perform(account_id, target_account_uri, relationship, options)
    from_account   = Account.find(account_id)
    target_domain  = domain(target_account_uri)
    target_account = resolve_target_account(target_account_uri, target_domain, relationship, options)
    options.symbolize_keys!

    if target_account.nil?
      # The controlled executor already claimed this target (queued). Since the
      # remote account could not be resolved, record a terminal delivery failure
      # so it does not sit stuck at queued. Failure-tolerant.
      mark_follow_import_target_unresolved(relationship, options)
      return
    end

    case relationship
    when 'follow'
      begin
        FollowService.new.call(from_account, target_account, **options.merge(tracking_moved_account: true))
      rescue ActiveRecord::RecordInvalid
        raise if FollowLimitValidator.limit_for_account(from_account) < from_account.following_count
      end
    when 'unfollow'
      UnfollowService.new.call(from_account, target_account)
    when 'block'
      BlockService.new.call(from_account, target_account)
    when 'unblock'
      UnblockService.new.call(from_account, target_account)
    when 'mute'
      MuteService.new.call(from_account, target_account, **options)
    when 'unmute'
      UnmuteService.new.call(from_account, target_account)
    when 'account_subscribe'
      AccountSubscribeService.new.call(from_account, target_account, **options)
    when 'account_unsubscribe'
      UnsubscribeAccountService.new.call(from_account, target_account, **options)
    end
  rescue ActiveRecord::RecordNotFound
    true
  end

  def resolve_target_account(target_account_uri, target_domain, relationship, options)
    resolve = lambda do
      stoplight_wrap_request(target_domain) { ResolveAccountService.new.call(target_account_uri, { check_delivery_availability: true }) }
    end

    target_id = follow_import_target_id(relationship, options)
    return resolve.call if target_id.blank?

    FollowImport::ResolutionObserver.observe(
      target_id: target_id,
      acct: target_account_uri,
      stoplight_wrapped: target_domain.present?,
      sidekiq_queue: 'pull',
      sidekiq_job_id: jid
    ) { resolve.call }
  end

  def follow_import_target_id(relationship, options)
    return unless relationship == 'follow'
    return if options.blank?

    options['follow_import_target_id'] || options[:follow_import_target_id]
  end

  def mark_follow_import_target_unresolved(relationship, options)
    return unless relationship == 'follow'

    target_id = options[:follow_import_target_id]
    return if target_id.blank?

    target = FollowImportTarget.find_by(id: target_id)
    return if target.nil?

    FollowImport::TargetTransitionService.new.mark_delivery_failed(target, failure_code: 'account_unresolved')
  rescue StandardError => e
    Rails.logger.warn("[Import::RelationshipWorker] failed to mark unresolved follow-import target: #{e.class}: #{e.message}")
  end

  def domain(uri)
    domain = uri.is_a?(Account) ? uri.domain : uri.split('@')[1]
    TagManager.instance.local_domain?(domain) ? nil : TagManager.instance.normalize_domain(domain)
  end

  def stoplight_wrap_request(domain, &block)
    if domain.present?
      Stoplight("source:#{domain}", &block)
        .with_fallback { nil }
        .with_threshold(1)
        .with_cool_off_time(5.minutes.seconds)
        .with_error_handler { |error, handle| error.is_a?(HTTP::Error) || error.is_a?(OpenSSL::SSL::SSLError) ? handle.call(error) : raise(error) }
        .run
    else
      block.call
    end
  end
end
