# frozen_string_literal: true

class ActivityPub::Activity::Update < ActivityPub::Activity
  SUPPORTED_TYPES = %w(Application Group Organization Person Service).freeze

  def perform
    @account.schedule_refresh_if_stale!

    dereference_object!

    if equals_or_includes_any?(@object['type'], SUPPORTED_TYPES)
      update_account
    elsif equals_or_includes_any?(@object['type'], %w(Note Question))
      update_status
    end
  rescue Mastodon::RejectPayload
    reject_payload!
  end

  private

  def update_account
    return if @account.uri != object_uri

    ActivityPub::ProcessAccountService.new.call(@account.username, @account.domain, @object, signed_with_known_key: true)
  end

  def update_status
    return reject_payload! if non_matching_uri_hosts?(@account.uri, object_uri)

    status = Status.find_by(uri: object_uri, account_id: @account.id)
    return if status.nil?

    ActivityPub::ProcessStatusUpdateService.new.call(status, @json, @object, request_id: @options[:request_id])
  end
end
