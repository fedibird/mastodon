# frozen_string_literal: true

class ProcessMentionsService < BaseService
  include Payloadable

  # Scan status for mentions and fetch remote mentioned users, create
  # local mention pointers, send Salmon notifications to mentioned
  # remote users
  # @param [Status] status
  # @param [Circle] circle
  # @param [Boolean] edit Reuse explicit mentions and silence removed ones.
  #   Circle and limited audiences are not rebuilt during an edit.
  def call(status, circle = nil, edit: false, save_records: true)
    return unless status.local?

    @status = status
    return process_edit! if edit
    return preview_mentions!(circle) unless save_records

    mentions = []

    status.text = status.text.gsub(Account::MENTION_RE) do |match|
      username, domain = Regexp.last_match(1).split('@')

      domain = begin
        if TagManager.instance.local_domain?(domain)
          nil
        else
          TagManager.instance.normalize_domain(domain)
        end
      end

      mentioned_account = Account.find_remote(username, domain)

      if mention_undeliverable?(mentioned_account)
        begin
          mentioned_account = resolve_account_service.call(Regexp.last_match(1))
        rescue Webfinger::Error, HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::UnexpectedResponseError
          mentioned_account = nil
        end
      end

      next match if mention_undeliverable?(mentioned_account) || mentioned_account&.suspended?
      next "@#{mentioned_account.acct}" if mentions.any? { |item| item.account_id == mentioned_account.id }

      mention = mentioned_account.mentions.new(status: status)
      mentions << mention if mention.save

      "@#{mentioned_account.acct}"
    end

    mentioned_account_ids = mentions.pluck(:account_id)

    if circle.present?
      (circle.class.name == 'Account' ? circle.mutuals : circle.accounts).find_each do |target_account|
        status.mentions.find_or_create_by(silent: true, account: target_account) unless mentioned_account_ids.include?(target_account.id)
      end
    elsif status.limited_visibility? && status.thread&.limited_visibility?
      # If we are replying to a local status, then we'll have the complete
      # audience copied here, both local and remote. If we are replying
      # to a remote status, only local audience will be copied. Then we
      # need to send our reply to the remote author's inbox for distribution

      status.thread.mentions.includes(:account).find_each do |mention|
        status.mentions.create(silent: true, account: mention.account) unless status.account_id == mention.account_id || mentioned_account_ids.include?(mention.account.id)
      end

      status.mentions.create(silent: true, account: status.thread.account) unless status.account_id == status.thread.account_id || mentioned_account_ids.include?(status.thread.account.id)
    end

    status.save!

    record_moderation_mentions!(mentions)

    # Silent mentions need to be delivered separately
    mentions.each { |mention| create_notification(mention) }
  end

  # Enqueue mention notifications and remote Create activities. Edit
  # processing returns the new rows and lets the caller invoke this only
  # after the surrounding transaction commits.
  def deliver_mention_notifications(mentions)
    Array(mentions).each { |mention| create_notification(mention) }
  end

  private

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
      username, domain = Regexp.last_match(1).split('@')

      domain = if TagManager.instance.local_domain?(domain)
                 nil
               else
                 TagManager.instance.normalize_domain(domain)
               end

      mentioned_account = Account.find_remote(username, domain)

      if mention_undeliverable?(mentioned_account)
        begin
          mentioned_account = resolve_account_service.call(Regexp.last_match(1))
        rescue Webfinger::Error, HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::UnexpectedResponseError
          mentioned_account = nil
        end
      end

      next match if mention_undeliverable?(mentioned_account) || mentioned_account&.suspended?

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

  # Build the same explicit, circle, and limited mentions without saving the
  # status, mention rows, moderation events, or notifications.
  def preview_mentions!(circle)
    mentions = []

    @status.text = @status.text.gsub(Account::MENTION_RE) do |match|
      username, domain = Regexp.last_match(1).split('@')

      domain = begin
        if TagManager.instance.local_domain?(domain)
          nil
        else
          TagManager.instance.normalize_domain(domain)
        end
      end

      mentioned_account = Account.find_remote(username, domain)

      if mention_undeliverable?(mentioned_account)
        begin
          mentioned_account = resolve_account_service.call(Regexp.last_match(1))
        rescue Webfinger::Error, HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::UnexpectedResponseError
          mentioned_account = nil
        end
      end

      next match if mention_undeliverable?(mentioned_account) || mentioned_account&.suspended?
      next "@#{mentioned_account.acct}" if mentions.any? { |mention| mention.account_id == mentioned_account.id }

      mentions << @status.mentions.new(account: mentioned_account)

      "@#{mentioned_account.acct}"
    end

    mentioned_account_ids = mentions.map(&:account_id)

    if circle.present?
      (circle.class.name == 'Account' ? circle.mutuals : circle.accounts).find_each do |target_account|
        mentions << @status.mentions.new(silent: true, account: target_account) unless mentioned_account_ids.include?(target_account.id)
      end
    elsif @status.limited_visibility? && @status.thread&.limited_visibility?
      @status.thread.mentions.includes(:account).find_each do |mention|
        mentions << @status.mentions.new(silent: true, account: mention.account) unless @status.account_id == mention.account_id || mentioned_account_ids.include?(mention.account.id)
      end

      unless @status.account_id == @status.thread.account_id || mentioned_account_ids.include?(@status.thread.account_id)
        mentions << @status.mentions.new(silent: true, account: @status.thread.account)
      end
    end

    mentions
  end

  def mention_undeliverable?(mentioned_account)
    mentioned_account.nil? || (!mentioned_account.local? && mentioned_account.ostatus?)
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
