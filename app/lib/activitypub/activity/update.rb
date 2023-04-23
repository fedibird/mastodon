# frozen_string_literal: true

class ActivityPub::Activity::Update < ActivityPub::Activity
  SUPPORTED_TYPES = %w(Application Group Organization Person Service).freeze

  def perform
    @account.schedule_refresh_if_stale!

    dereference_object!

    if equals_or_includes_any?(@object['type'], SUPPORTED_TYPES)
      update_account
    elsif equals_or_includes_any?(@object['type'], %w(Question))
      update_poll
    end
  end

  private

  def update_account
    return if @account.uri != object_uri

    ActivityPub::ProcessAccountService.new.call(@account.username, @account.domain, @object, signed_with_known_key: true)
  end

  def update_poll
    return reject_payload! if non_matching_uri_hosts?(@account.uri, @object['id'])

    status = Status.find_by(uri: object_uri, account_id: @account.id)
    return if status.nil? || status.preloadable_poll.nil?

    ActivityPub::ProcessPollService.new.call(status.preloadable_poll, @object)
  end
end
