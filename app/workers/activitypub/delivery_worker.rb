# frozen_string_literal: true

class ActivityPub::DeliveryWorker
  include Sidekiq::Worker
  include RoutingHelper
  include JsonLdHelper

  STOPLIGHT_FAILURE_THRESHOLD = 10
  STOPLIGHT_COOLDOWN = 60

  sidekiq_options queue: 'push', retry: 16, dead: false

  # Terminal delivery failure: only once all retries are exhausted (never on an
  # intermediate retry). Routes optional opaque delivery_tracking metadata to its
  # generic handler. Failure-tolerant.
  sidekiq_retries_exhausted do |msg|
    options  = msg['args'][3] || {}
    tracking = options['delivery_tracking']

    if tracking.present?
      begin
        ActiveRecord::Base.connection_pool.with_connection do
          ActivityPub::DeliveryTracking.failed(tracking)
        end
      rescue StandardError => e
        Rails.logger.warn("[ActivityPub::DeliveryWorker] retries-exhausted tracking failed: #{e.class}: #{e.message}")
      end
    end
  end

  HEADERS = { 'Content-Type' => 'application/activity+json' }.freeze

  def perform(json, source_account_id, inbox_url, options = {})
    @options        = options.with_indifferent_access
    started_at      = Time.now.utc
    error           = nil

    begin
      unless @options[:bypass_availability] || DeliveryFailureTracker.available?(inbox_url)
        @delivery_skip_reason = 'availability_suppression'
        return
      end

      @json           = json
      @source_account = Account.find(source_account_id)
      @inbox_url      = inbox_url
      @host           = Addressable::URI.parse(inbox_url).normalized_site
      @performed      = false

      perform_request

      # HTTP delivery succeeded; route optional tracking metadata to its generic
      # handler. Delivery success is only that — not follow acceptance.
      track_delivery_success! if @performed
    rescue StandardError => e
      error = e
      raise
    ensure
      if @inbox_url.present?
        if @performed
          failure_tracker.track_success!
        else
          failure_tracker.track_failure!
        end
      end

      record_follow_import_delivery_observation(inbox_url, started_at, error)
    end
  end

  private

  def record_follow_import_delivery_observation(inbox_url, started_at, error)
    FollowImport::DeliveryObserver.record_attempt(
      options: @options,
      inbox_url: inbox_url,
      sidekiq_queue: 'push',
      sidekiq_job_id: jid,
      started_at: started_at,
      response: @http_response,
      error: error,
      skip_reason: @delivery_skip_reason,
      performed: @performed
    )
  end

  def track_delivery_success!
    tracking = @options[:delivery_tracking]
    return if tracking.blank?

    # DeliveryTracking swallows its own errors, so this never breaks/retries a
    # successful delivery.
    ActivityPub::DeliveryTracking.delivered(tracking.to_h)
  end

  def build_request(http_client)
    Request.new(:post, @inbox_url, body: @json, http_client: http_client).tap do |request|
      request.on_behalf_of(@source_account, :uri, sign_with: @options[:sign_with])
      request.add_headers(HEADERS)
      request.add_headers({ 'Collection-Synchronization' => synchronization_header }) if ENV['DISABLE_FOLLOWERS_SYNCHRONIZATION'] != 'true' && @options[:synchronize_followers]
    end
  end

  def synchronization_header
    "collectionId=\"#{account_followers_url(@source_account)}\", digest=\"#{@source_account.remote_followers_hash(@inbox_url)}\", url=\"#{account_followers_synchronization_url(@source_account)}\""
  end

  def perform_request
    light = Stoplight(@inbox_url) do
      request_pool.with(@host) do |http_client|
        build_request(http_client).perform do |response|
          @http_response = response
          raise Mastodon::UnexpectedResponseError, response unless response_successful?(response) || response_error_unsalvageable?(response) || unsalvageable_authorization_failure?(response)

          @performed = true
        end
      end
    end

    light.with_threshold(STOPLIGHT_FAILURE_THRESHOLD)
         .with_cool_off_time(STOPLIGHT_COOLDOWN)
         .run
  end

  def unsalvageable_authorization_failure?(response)
    @source_account.suspended_permanently? && response.code == 401
  end

  def failure_tracker
    @failure_tracker ||= DeliveryFailureTracker.new(@inbox_url)
  end

  def request_pool
    RequestPool.current
  end
end
