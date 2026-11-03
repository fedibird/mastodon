# frozen_string_literal: true

require 'digest'
require 'singleton'

class EntityCache
  include Singleton

  MAX_EXPIRATION = 7.days.freeze
  MIN_EXPIRATION = 60.seconds.freeze

  def status(url)
    return if url.blank?

    # Never fold URL path casing when caching fetched remote identities.
    Rails.cache.fetch(resource_url_cache_key(:status_v2, url), expires_in: MAX_EXPIRATION) { FetchRemoteStatusService.new.call(url) }
  end

  def mention(username, domain)
    Rails.cache.fetch(to_key(:mention, username, domain), expires_in: MAX_EXPIRATION) { Account.select(:id, :username, :domain, :url, :actor_type, :moved_to_account_id).find_remote(username, domain) }
  end

  def emoji(shortcodes, domain)
    shortcodes = Array(shortcodes)
    return [] if shortcodes.empty?

    cached       = Rails.cache.read_multi(*shortcodes.map { |shortcode| to_key(:emoji, shortcode, domain) })
    uncached_ids = []

    shortcodes.each do |shortcode|
      uncached_ids << shortcode unless cached.key?(to_key(:emoji, shortcode, domain))
    end

    unless uncached_ids.empty?
      uncached = CustomEmoji.where(shortcode: shortcodes, domain: domain, disabled: false).index_by(&:shortcode)
      uncached.each_value { |item| Rails.cache.write(to_key(:emoji, item.shortcode, domain), item, expires_in: MAX_EXPIRATION) }
    end

    shortcodes.filter_map { |shortcode| cached[to_key(:emoji, shortcode, domain)] || uncached[shortcode] }
  end

  def holding_account(url)
    return if url.blank?

    cache_key = resource_url_cache_key(:holding_account_v2, url)
    return Rails.cache.read(cache_key) if Rails.cache.exist?(cache_key)

    account = begin
      if ActivityPub::TagManager.instance.local_uri?(url)
        recognized_params = Rails.application.routes.recognize_path(url) rescue {}

        if recognized_params[:action] == 'show' && %w(accounts activitypub/accounts).include?(recognized_params[:controller])
          Account.find_local(recognized_params[:username])
        end
      else
        ActivityPub::KnownResourceResolver.new(url).account
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    Rails.cache.write(cache_key, account, expires_in: account.nil? ? MIN_EXPIRATION : MAX_EXPIRATION)

    account
  end

  def holding_status(url)
    return if url.blank?

    cache_key = resource_url_cache_key(:holding_status_v2, url)
    if Rails.cache.exist?(cache_key)
      cached_status = Rails.cache.read(cache_key)
      return cached_status if cached_status&.uri == url

      # A previously verified alternate (or a negative cache entry) must not
      # shadow an AP object that has since arrived with this exact id.
      identity = Status.find_by(uri: url)
      return identity unless identity.nil?

      return cached_status
    end

    status = begin
      if ActivityPub::TagManager.instance.local_uri?(url)
        StatusFinder.new(url).status
      else
        ActivityPub::KnownResourceResolver.new(url).status
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    update_holding_status(url, status)

    status
  end

  def update_holding_status(url, status)
    return if url.blank?

    # This method is also called after FetchResourceService has discovered
    # a verified HTML -> ActivityPub alternate in StatusReferenceResolveWorker.
    status = Status.find_by(id: status&.id)
    Rails.cache.write(resource_url_cache_key(:holding_status_v2, url), status, expires_in: status.nil? ? MIN_EXPIRATION : MAX_EXPIRATION)
  end

  def resource_url_cache_key(type, url)
    # URL paths are case-sensitive. Do not use to_key's downcasing, and avoid
    # putting potentially very long remote URLs directly into cache keys.
    "#{type}:#{Digest::SHA256.hexdigest(url)}"
  end

  def to_key(type, *ids)
    "#{type}:#{ids.compact.map(&:downcase).join(':')}"
  end
end
