# frozen_string_literal: true

class ResolveURLService < BaseService
  include JsonLdHelper
  include Authorization

  def call(url, **options)
    @url          = url
    @options      = options.symbolize_keys!
    @on_behalf_of = @options[:on_behalf_of].presence

    if local_url?
      process_local_url
    elsif !fetched_resource.nil?
      process_url
    else
      process_url_from_db
    end
  end

  private

  def process_url
    if equals_or_includes_any?(type, ActivityPub::FetchRemoteAccountService::SUPPORTED_TYPES)
      ActivityPub::FetchRemoteAccountService.new.call(resource_url, prefetched_body: body)
    elsif equals_or_includes_any?(type, ActivityPub::Activity::Create::SUPPORTED_TYPES + ActivityPub::Activity::Create::CONVERTED_TYPES)
      status = FetchRemoteStatusService.new.call(resource_url, body, **@options)
      authorize_with @on_behalf_of, status, :show? unless status.nil?
      status
    elsif equals_or_includes_any?(type, %w(Emoji))
      FetchRemoteCustomEmojiService.new.call(resource_url, body)
    end
  end

  def process_url_from_db
    return unless @on_behalf_of.present? && [401, 403, 404].include?(fetch_resource_service.response_code)

    # It may happen that the resource is a private toot, and thus not fetchable,
    # but we can return the toot if we already know about it.
    # Resolve via the indexed ActivityPub identifier, not a status.url scan.
    # A Mastodon-style public URL can supply a candidate uri, which must also
    # be checked against the stored public URL.
    status = ActivityPub::KnownResourceResolver.new(@url).status

    authorize_with @on_behalf_of, status, :show? unless status.nil?
    status
  rescue Mastodon::NotPermittedError
    nil
  end

  def fetched_resource
    @fetched_resource ||= fetch_resource_service.call(@url)
  end

  def fetch_resource_service
    @_fetch_resource_service ||= FetchResourceService.new
  end

  def resource_url
    fetched_resource.first
  end

  def body
    fetched_resource.second[:prefetched_body]
  end

  def type
    json_data['type']
  end

  def json_data
    @json_data ||= body_to_json(body)
  end

  def local_url?
    TagManager.instance.local_url?(@url)
  end

  def process_local_url
    recognized_params = Rails.application.routes.recognize_path(@url) rescue {}

    return unless recognized_params[:action] == 'show'

    if %w(statuses activitypub/statuses).include?(recognized_params[:controller])
      status = Status.find_by(id: recognized_params[:id])
      check_local_status(status)
    elsif %w(accounts activitypub/accounts).include?(recognized_params[:controller])
      Account.find_local(recognized_params[:username])
    elsif recognized_params[:controller] == 'emojis'
      CustomEmoji.find_by(shortcode: recognized_params[:id], domain: nil)
    end
  end

  def check_local_status(status)
    return if status.nil?

    authorize_with @on_behalf_of, status, :show?
    status
  rescue Mastodon::NotPermittedError
    nil
  end
end
