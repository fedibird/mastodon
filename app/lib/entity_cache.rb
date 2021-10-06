# frozen_string_literal: true

require 'singleton'

class EntityCache
  include Singleton

  MAX_EXPIRATION = 7.days.freeze
  MIN_EXPIRATION = 60.seconds.freeze

  def status(url)
    Rails.cache.fetch(to_key(:status, url), expires_in: MAX_EXPIRATION) { FetchRemoteStatusService.new.call(url) }
  end

  def mention(username, domain)
    Rails.cache.fetch(to_key(:mention, username, domain), expires_in: MAX_EXPIRATION) { Account.select(:id, :username, :domain, :url, :actor_type).find_remote(username, domain) }
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

  def holding_status_and_account(url)
    return Rails.cache.read(to_key(:holding_status, url)) if Rails.cache.exist?(to_key(:holding_status, url))

    status = begin
      if ActivityPub::TagManager.instance.local_uri?(url)
        StatusFinder.new(url).status
      else
        Status.where(uri: url).or(Status.where(url: url)).first
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    account = status&.account

    Rails.cache.write(to_key(:holding_status, url), [status, account], expires_in: account.nil? ? MIN_EXPIRATION : MAX_EXPIRATION)

    [status, account]
  end

  def to_key(type, *ids)
    "#{type}:#{ids.compact.map(&:downcase).join(':')}"
  end
end
