# frozen_string_literal: true

class ProcessMentionsService < BaseService
  include Payloadable

  # Scan status for mentions and fetch remote mentioned users, create
  # local mention pointers, send Salmon notifications to mentioned
  # remote users.
  #
  # Resolution (including remote account lookup) finishes before any
  # Status or Mention write. Passing a persisted status with
  # +save_records: true+ then stores mention rows in a short transaction
  # and only afterwards records moderation and enqueues delivery.
  # @param [Status] status
  # @param [Circle, Account, nil] circle
  # @param [Boolean] edit Reuse explicit mentions and silence removed ones.
  #   Circle and limited audiences are not rebuilt during an edit.
  # @param [Boolean] save_records When false, resolve explicit mentions
  #   and rewrite text in memory only. Silent audiences are not attached.
  # @return [Array<Mention>] explicit mentions, or mentions introduced by an edit
  def call(status, circle = nil, edit: false, save_records: true)
    return unless status.local?

    @status = status
    return process_edit! if edit

    explicit = prepare(status, circle, silent_audience: save_records)
    return explicit unless save_records

    ApplicationRecord.transaction do
      persist_mentions!(status)
    end

    record_and_deliver!(explicit)
    explicit
  end

  # Resolve explicit mentions and attach unsaved explicit and, when
  # requested, silent mention rows. Performs account resolution and may
  # do network I/O. Does not INSERT or UPDATE Status or Mention.
  # @return [Array<Mention>] explicit mentions to notify after commit
  def prepare(status, circle = nil, silent_audience: true)
    return [] unless status.local?

    @status = status
    explicit = resolve_explicit_mentions!(status)
    attach_silent_audience!(status, circle) if silent_audience
    explicit
  end

  # Persist rewritten text and unsaved mention rows. Call inside the
  # transaction that owns a new status, after that status has been saved.
  def persist_mentions!(status)
    @status = status
    status.save! if status.persisted? && status.changed?

    status.mentions.each do |mention|
      mention.save! if mention.new_record?
    end
  end

  # Moderation rows plus mention notification and ActivityPub delivery.
  # Call only after the status transaction has committed so a Sidekiq
  # worker cannot run against a status or mention that is not yet visible.
  def record_and_deliver!(mentions)
    mentions = Array(mentions)
    record_moderation_mentions!(mentions)
    deliver_mention_notifications(mentions)
  end

  # Enqueue mention notifications and remote Create activities. Edit
  # processing returns the new rows and lets the caller invoke this only
  # after the surrounding transaction commits.
  def deliver_mention_notifications(mentions)
    Array(mentions).each { |mention| create_notification(mention) }
  end

  private

  def resolve_explicit_mentions!(status)
    mentions = []

    status.text = status.text.gsub(Account::MENTION_RE) do |match|
      mentioned_account = resolve_mentioned_account(Regexp.last_match(1))
      next match if mentioned_account.nil?
      next "@#{mentioned_account.acct}" if mentions.any? { |item| item.account_id == mentioned_account.id }

      mentions << status.mentions.new(account: mentioned_account)
      "@#{mentioned_account.acct}"
    end

    mentions
  end

  # Local lookup, domain normalization, and remote resolution. Network
  # failures that have always been ignored leave the original text in place.
  # Any other error propagates so the caller can avoid saving a status.
  def resolve_mentioned_account(acct)
    username, domain = acct.split('@')

    domain = if TagManager.instance.local_domain?(domain)
               nil
             else
               TagManager.instance.normalize_domain(domain)
             end

    mentioned_account = Account.find_remote(username, domain)

    if mention_undeliverable?(mentioned_account)
      begin
        mentioned_account = resolve_account_service.call(acct)
      rescue Webfinger::Error, HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::UnexpectedResponseError
        mentioned_account = nil
      end
    end

    return if mention_undeliverable?(mentioned_account) || mentioned_account&.suspended?

    mentioned_account
  end

  def attach_silent_audience!(status, circle)
    mentioned_account_ids = status.mentions.map(&:account_id)

    if circle.present?
      append_silent_mentions!(status, circle_accounts(circle), mentioned_account_ids)
    elsif status.limited_visibility? && status.thread&.limited_visibility?
      append_limited_thread_audience!(status, mentioned_account_ids)
    end
  end

  def circle_accounts(circle)
    circle.instance_of?(Account) ? circle.mutuals : circle.accounts
  end

  def append_silent_mentions!(status, accounts, mentioned_account_ids)
    accounts.find_each do |target_account|
      next if mentioned_account_ids.include?(target_account.id)

      status.mentions.build(silent: true, account: target_account)
      mentioned_account_ids << target_account.id
    end
  end

  def append_limited_thread_audience!(status, mentioned_account_ids)
    thread = status.thread

    thread.mentions.includes(:account).find_each do |mention|
      next if status.account_id == mention.account_id || mentioned_account_ids.include?(mention.account_id)

      status.mentions.build(silent: true, account: mention.account)
      mentioned_account_ids << mention.account_id
    end

    return if status.account_id == thread.account_id || mentioned_account_ids.include?(thread.account_id)

    status.mentions.build(silent: true, account: thread.account)
  end

  def mention_undeliverable?(mentioned_account)
    mentioned_account.nil? || (!mentioned_account.local? && mentioned_account.ostatus?)
  end

  # Record explicit (non-silent) mentions as interaction signals. A mention
  # aimed at the account being replied to is recorded as a reply.
  def record_moderation_mentions!(mentions)
    mentions.each do |mention|
      event_type = @status.in_reply_to_account_id.present? && @status.in_reply_to_account_id == mention.account_id ? :reply : :mention

      Moderation::EventRecorder.record_interaction(
        actor: @status.account,
        target: mention.account,
        event_type: event_type,
        status: @status,
        source_record: mention
      )
    end
  end

  # Explicit mentions already stored are reused. Mentions dropped from the
  # text become silent instead of being deleted, and circle or limited
  # silent audiences are left in place. Moderation and notifications run
  # only for mention rows created by this edit.
  def process_edit!
    existing = @status.mentions.includes(:account).to_a
    current  = []
    introduced = []

    @status.text = @status.text.to_s.gsub(Account::MENTION_RE) do |match|
      mentioned_account = resolve_mentioned_account(Regexp.last_match(1))
      next match if mentioned_account.nil?

      mention = current.find { |item| item.account_id == mentioned_account.id }
      mention ||= existing.find { |item| item.account_id == mentioned_account.id }
      mention ||= mentioned_account.mentions.new(status: @status)
      mention.silent = false
      current << mention unless current.include?(mention)

      "@#{mentioned_account.acct}"
    end

    current.each do |mention|
      if mention.new_record?
        introduced << mention if mention.save
      elsif mention.changed?
        mention.save!
      end
    end

    removed = existing.select { |mention| !mention.silent? && !current.include?(mention) }
    Mention.where(id: removed.map(&:id)).update_all(silent: true) if removed.any?

    @status.save!

    record_moderation_mentions!(introduced)
    introduced
  end

  def create_notification(mention)
    mentioned_account = mention.account
    status            = mention.status || @status

    if mentioned_account.local? && mentioned_account.group?
      group      = mentioned_account
      visibility = Status.visibilities.key([Status.visibilities[status.visibility], Status.visibilities[group.user&.setting_default_privacy]].max)

      ReblogService.new.call(group, status, { visibility: visibility })
    elsif mentioned_account.local?
      LocalNotificationWorker.perform_async(mentioned_account.id, mention.id, mention.class.name, 'mention')
    elsif mentioned_account.activitypub?
      ActivityPub::DeliveryWorker.perform_async(activitypub_json(node_software_name(mentioned_account.inbox_url), status), status.account_id, mentioned_account.inbox_url, { 'synchronize_followers' => !status.distributable? })
    end
  end

  def node_software_name(inbox_url)
    Node.find_domain(Addressable::URI.parse(inbox_url).normalized_host.to_s.downcase)&.software_name
  end

  def activitypub_json(software, status = @status)
    @activitypub_json ||= {}
    software = '(general)' if software.blank?
    @activitypub_json[software] ||= Oj.dump(serialize_payload(ActivityPub::ActivityPresenter.from_status(status), ActivityPub::ActivitySerializer, signer: status.account, software: software))
  end

  def resolve_account_service
    ResolveAccountService.new
  end
end
