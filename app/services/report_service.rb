# frozen_string_literal: true

class ReportService < BaseService
  include Payloadable

  def call(source_account, target_account, options = {})
    @source_account = source_account
    @target_account = target_account
    @status_ids     = options.delete(:status_ids) || []
    @comment        = options.delete(:comment) || ''
    @category       = options[:rule_ids].present? ? 'violation' : (options.delete(:category).presence || 'other')
    @rule_ids       = options.delete(:rule_ids).presence
    @options        = options

    raise ActiveRecord::RecordNotFound if @target_account.suspended?

    create_report!
    record_moderation_rejection!
    notify_staff!

    if forward?
      forward_to_origin!
      forward_to_replied_to!
    end

    @report
  end

  private

  def record_moderation_rejection!
    Moderation::EventRecorder.record_rejection(
      rejector: @source_account,
      rejected: @target_account,
      event_type: :report,
      source_record: @report,
      metadata: { status_count: @status_ids.size }
    )
  end

  def create_report!
    @report = @source_account.reports.create!(
      target_account: @target_account,
      status_ids: @status_ids,
      comment: @comment,
      uri: @options[:uri],
      forwarded: forward_to_origin?,
      category: @category,
      rule_ids: @rule_ids
    )
  end

  def notify_staff!
    return if @report.unresolved_siblings?

    User.those_who_can(:manage_reports).includes(:account).find_each do |user|
      next unless user.functional?

      LocalNotificationWorker.perform_async(user.account_id, @report.id, 'Report', 'admin.report')
      AdminMailer.new_report(user.account, @report).deliver_later if user.allows_report_emails?
    end
  end

  def forward_to_origin!
    return unless forward_to_origin?

    ActivityPub::DeliveryWorker.perform_async(
      payload,
      some_local_account.id,
      @target_account.inbox_url
    )
  end

  def forward_to_replied_to!
    replied_to_account_ids = Status.where(id: @status_ids).where.not(in_reply_to_account_id: nil).select(:in_reply_to_account_id)
    inbox_urls = Account.remote.where(domain: forward_to_domains).where(id: replied_to_account_ids).inboxes
    inbox_urls -= [@target_account.inbox_url, @target_account.shared_inbox_url]

    inbox_urls.each do |inbox_url|
      ActivityPub::DeliveryWorker.perform_async(
        payload,
        some_local_account.id,
        inbox_url
      )
    end
  end

  def forward?
    !@target_account.local? && ActiveModel::Type::Boolean.new.cast(@options[:forward])
  end

  def forward_to_origin?
    forward? && forward_to_domains.include?(@target_account.domain)
  end

  def forward_to_domains
    @forward_to_domains ||= (@options[:forward_to_domains] || [@target_account.domain]).filter_map { |domain| TagManager.instance.normalize_domain(domain&.strip) }.uniq
  end

  def payload
    Oj.dump(serialize_payload(@report, ActivityPub::FlagSerializer, account: some_local_account))
  end

  def some_local_account
    @some_local_account ||= Account.representative
  end
end
