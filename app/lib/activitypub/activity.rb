# frozen_string_literal: true

class ActivityPub::Activity
  include JsonLdHelper
  include Redisable
  include Lockable

  SUPPORTED_TYPES = %w(Note Question).freeze
  CONVERTED_TYPES = %w(Image Audio Video Article Page Event).freeze

  def initialize(json, account, **options)
    @json    = json
    @account = account
    @object  = @json['object']
    @options = options.symbolize_keys!
  end

  def perform
    raise NotImplementedError
  end

  class << self
    def factory(json, account, **options)
      @json = json
      klass&.new(json, account, **options)
    end

    private

    def klass
      case @json['type']
      when 'Create'
        ActivityPub::Activity::Create
      when 'Announce'
        ActivityPub::Activity::Announce
      when 'Delete'
        ActivityPub::Activity::Delete
      when 'Follow'
        ActivityPub::Activity::Follow
      when 'Like', 'EmojiReact'
        ActivityPub::Activity::Like
      when 'Block'
        ActivityPub::Activity::Block
      when 'Update'
        ActivityPub::Activity::Update
      when 'Undo'
        ActivityPub::Activity::Undo
      when 'Accept'
        ActivityPub::Activity::Accept
      when 'Reject'
        ActivityPub::Activity::Reject
      when 'Flag'
        ActivityPub::Activity::Flag
      when 'Add'
        ActivityPub::Activity::Add
      when 'Remove'
        ActivityPub::Activity::Remove
      when 'Move'
        ActivityPub::Activity::Move
      end
    end
  end

  protected

  def status_from_uri(uri)
    ActivityPub::TagManager.instance.uri_to_resource(uri, Status)
  end

  def account_from_uri(uri)
    ActivityPub::TagManager.instance.uri_to_resource(uri, Account)
  end

  def object_uri
    @object_uri ||= begin
      str = value_or_id(@object)

      if str&.start_with?('bear:')
        Addressable::URI.parse(str).query_values['u']
      else
        str
      end
    end
  end

  def unsupported_object_type?
    @object.is_a?(String) || !(supported_object_type? || converted_object_type?)
  end

  def supported_object_type?
    equals_or_includes_any?(@object['type'], SUPPORTED_TYPES)
  end

  def converted_object_type?
    equals_or_includes_any?(@object['type'], CONVERTED_TYPES)
  end

  def distribute(status)
    crawl_links(status)

    return unless @options[:delivery]

    notify_about_reblog(status) if reblog_of_local_account?(status) && !reblog_by_following_group_account?(status)
    notify_about_mentions(status)

    # Only continue if the status is supposed to have arrived in real-time.
    # Note that if @options[:override_timestamps] isn't set, the status
    # may have a lower snowflake id than other existing statuses, potentially
    # "hiding" it from paginated API calls
    return unless @options[:override_timestamps] || status.within_realtime_window?

    distribute_to_followers(status)
  end

  def reblog_of_local_account?(status)
    status.reblog? && status.reblog.account.local?
  end

  def reblog_by_following_group_account?(status)
    status.reblog? && status.account.group? && status.reblog.account.following?(status.account)
  end

  def notify_about_reblog(status)
    NotifyService.new.call(status.reblog.account, :reblog, status)
  end

  def notify_about_mentions(status)
    status.active_mentions.includes(:account).each do |mention|
      next unless mention.account.local? && audience_includes?(mention.account)
      NotifyService.new.call(mention.account, :mention, mention)
    end
  end

  def crawl_links(status)
    case FetchLinkCardService.new.link_type(status)
    when :include_redirect
      redis.sadd("statuses/#{status.id}/processing", 'LinkCrawlWorker')
      redis.expire("statuses/#{status.id}/processing", 60.seconds)
      LinkCrawlWorker.new.perform(status.id)
    when :include
      # Spread out crawling randomly to avoid DDoSing the link
      random_seconds = rand(1..59).seconds
      redis.sadd("statuses/#{status.id}/processing", 'LinkCrawlWorker')
      redis.expire("statuses/#{status.id}/processing", random_seconds + 60.seconds)
      LinkCrawlWorker.perform_in(random_seconds, status.id)
    end
  rescue Addressable::URI::InvalidURIError
    true
  end

  def distribute_to_followers(status)
    status.account.high_priority? ?
      PriorityDistributionWorker.perform_async(status.id) :
      DistributionWorker.perform_async(status.id)
  end

  def delete_arrived_first?(uri)
    redis.exists?("delete_upon_arrival:#{@account.id}:#{uri}")
  end

  def delete_later!(uri)
    redis.setex("delete_upon_arrival:#{@account.id}:#{uri}", 6.hours.seconds, true)
  end

  def status_from_object
    # If the status is already known, return it
    status = status_from_uri(object_uri)

    return status unless status.nil?

    dereference_object!

    # If the boosted toot is embedded and it is a self-boost or dereferenced, handle it like a Create
    unless unsupported_object_type?
      actor_id = value_or_id(first_of_value(@object['attributedTo']))

      if actor_id == @account.uri
        return ActivityPub::Activity.factory({ 'type' => 'Create', 'actor' => actor_id, 'object' => @object }, @account, **@options.merge(delivery: false)).perform
      end
    end

    fetch_remote_original_status
  end

  def dereferenced?
    @dereferenced
  end

  def dereference_object!
    return unless @object.is_a?(String)

    dereferencer = ActivityPub::Dereferencer.new(@object, permitted_origin: @account.uri, signature_account: signed_fetch_account)

    @dereferenced = !dereferencer.object.nil?
    @object = dereferencer.object unless dereferencer.object.nil?
  end

  def signed_fetch_account
    return Account.find(@options[:delivered_to_account_id]) if @options[:delivered_to_account_id].present?

    first_mentioned_local_account || first_local_follower
  end

  def first_mentioned_local_account
    audience = (as_array(@json['to']) + as_array(@json['cc'])).map { |x| value_or_id(x) }.uniq
    local_usernames = audience.select { |uri| ActivityPub::TagManager.instance.local_uri?(uri) }
                              .map { |uri| ActivityPub::TagManager.instance.uri_to_local_id(uri, :username) }

    return if local_usernames.empty?

    Account.local.where(username: local_usernames).first
  end

  def first_local_follower
    @account.followers.local.first
  end

  def follow_request_from_object
    @follow_request ||= FollowRequest.find_by(target_account: @account, uri: object_uri) unless object_uri.nil?
  end

  def follow_from_object
    @follow ||= ::Follow.find_by(target_account: @account, uri: object_uri) unless object_uri.nil?
  end

  def fetch_remote_original_status
    if object_uri.start_with?('http')
      return if ActivityPub::TagManager.instance.local_uri?(object_uri)

      if dereferenced?
        ActivityPub::FetchRemoteStatusService.new.call(object_uri, prefetched_body: @object)
      else
        ActivityPub::FetchRemoteStatusService.new.call(object_uri, on_behalf_of: @account.followers.local.first)
      end
    elsif @object['url'].present?
      ::FetchRemoteStatusService.new.call(@object['url'])
    end
  end

  def fetch?
    !@options[:delivery]
  end

  def followed_by_local_accounts?
    @account.passive_relationships.exists? || @options[:relayed_through_account]&.passive_relationships&.exists?
  end

  def requested_through_relay?
    @options[:relayed_through_account] && Relay.find_by(inbox_url: @options[:relayed_through_account].inbox_url)&.enabled?
  end

  def reject_payload!
    Rails.logger.info("Rejected #{@json['type']} activity #{@json['id']} from #{@account.uri}#{@options[:relayed_through_account] && "via #{@options[:relayed_through_account].uri}"}")
    nil
  end

  def audience_to
    as_array(@json['to']).map { |x| value_or_id(x) }
  end

  def audience_cc
    as_array(@json['cc']).map { |x| value_or_id(x) }
  end

  def audience_searchable_by
    return nil if @object['searchableBy'].nil?

    as_array(@object['searchableBy']).map { |x| value_or_id(x) }
  end

  def process_audience
    conversation_uri = value_or_id(@object['context'])

    (audience_to + audience_cc).uniq.each do |audience|
      next if ActivityPub::TagManager.instance.public_collection?(audience) || audience == conversation_uri

      # Unlike with tags, there is no point in resolving accounts we don't already
      # know here, because silent mentions would only be used for local access
      # control anyway
      account = account_from_uri(audience)

      next if account.nil? || @mentions.any? { |mention| mention.account_id == account.id }

      @mentions << Mention.new(account: account, silent: true)

      # If there is at least one silent mention, then the status can be considered
      # as a limited-audience status, and not strictly a direct message, but only
      # if we considered a direct message in the first place
      @params[:visibility] = :limited if @params[:visibility] == :direct
    end

    # If the payload was delivered to a specific inbox, the inbox owner must have
    # access to it, unless they already have access to it anyway
    return if @options[:delivered_to_account_id].nil? || @mentions.any? { |mention| mention.account_id == @options[:delivered_to_account_id] }

    @mentions << Mention.new(account_id: @options[:delivered_to_account_id], silent: true)

    @params[:visibility] = :limited if @params[:visibility] == :direct
  end

  def postprocess_audience_and_deliver
    return if @status.mentions.find_by(account_id: @options[:delivered_to_account_id])

    delivered_to_account = Account.find(@options[:delivered_to_account_id])

    @status.mentions.create(account: delivered_to_account, silent: true)
    @status.update(visibility: :limited) if @status.direct_visibility?

    return unless delivered_to_account.following?(@account)

    @account.high_priority? ?
      PriorityFeedInsertWorker.perform_async(@status.id, delivered_to_account.id, 'home') :
      FeedInsertWorker.perform_async(@status.id, delivered_to_account.id, 'home')
  end

  def visibility_from_audience
    if audience_to.any? { |to| ActivityPub::TagManager.instance.public_collection?(to) }
      :public
    elsif audience_cc.any? { |cc| ActivityPub::TagManager.instance.public_collection?(cc) }
      :unlisted
    elsif audience_to.include?(@account.followers_url)
      :private
    elsif audience_to.empty? && audience_cc.empty?
      :personal
    else
      :direct
    end
  end

  def visibility_from_audience_with_correction
    visibility = visibility_from_audience
    visibility = apply_silence_to_visibility(visibility)
    visibility = apply_deny_subscribed_to_visibility(visibility)    
  end

  def apply_silence_to_visibility(visibility)
    if @account.hard_silenced? && %i(public, unlisted).include?(visibility)
      :private
    elsif @account.silenced? && %i(public).include?(visibility)
      :unlisted
    else
      visibility
    end
  end

  def apply_deny_subscribed_to_visibility(visibility)
    if @account.deny_subscribed? && %i(public).include?(visibility)
      :unlisted
    else
      visibility
    end
  end

  def audience_includes?(account)
    uri = ActivityPub::TagManager.instance.uri_for(account)
    audience_to.include?(uri) || audience_cc.include?(uri)
  end

  def searchability_from_audience
    if audience_searchable_by.blank?
      nil
    elsif audience_searchable_by.any? { |uri| ActivityPub::TagManager.instance.public_collection?(uri) }
      :public
    elsif audience_searchable_by.include?(@account.followers_url)
      :private
    elsif audience_searchable_by == [ActivityPub::TagManager.instance.uri_for(@account)]
      :direct
    else
      :direct
    end
  end

  def searchability
    searchability = searchability_from_audience

    return nil if searchability.nil?

    visibility = visibility_from_audience_with_correction

    if searchability === visibility
      searchability
    elsif [:public, :private].include?(searchability) && [:public, :unlisted].include?(visibility)
      :private
    else
      :direct
    end
  end
end
