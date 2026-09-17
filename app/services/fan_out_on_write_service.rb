# frozen_string_literal: true

class FanOutOnWriteService < BaseService
  include Redisable

  # Transport-only field for Node streaming Filter keyword matching.
  # Must not be added to REST::StatusSerializer. Node strips it before
  # transmitting to clients.
  STREAMING_SEARCHABLE_TEXT_KEY = '_fedibird_searchable_text'

  # Push a status into home and mentions feeds
  # @param [Status] status
  def call(status)
    raise Mastodon::RaceConditionError if status.visibility.nil?

    @feedInsertWorker = status.account.high_priority? ? ::PriorityFeedInsertWorker : FeedInsertWorker

    deliver_to_self(status) if status.account.local? && !(status.direct_visibility? && status.account.user.setting_hide_direct_from_timeline)

    if status.personal_visibility?
      deliver_to_self_included_lists(status) if status.account.local? && !status.account.user.setting_hide_personal_from_timeline
      return
    elsif status.direct_visibility?
      deliver_to_mentioned_followers(status)
      deliver_to_mentioned_lists(status)
      deliver_to_own_conversation(status)
    elsif status.limited_visibility?
      deliver_to_mentioned_followers(status)
      deliver_to_mentioned_lists(status)
    else
      deliver_to_followers(status)
      deliver_to_lists(status)
    end

    if status.account.group?
      if status.reblog?
        render_anonymous_reblog_payload(status)
      else
        render_anonymous_payload(status)
      end

      deliver_to_group(status)
    end

    deliver_to_hashtag_followers(status)
    deliver_to_keyword_subscribers(status)

    return if status.account.silenced? || !status.public_visibility?

    render_anonymous_payload(status)

    if !status.reblog? && (!status.reply? || status.in_reply_to_account_id == status.account_id)
      deliver_to_public(status)
      deliver_to_index(status)
      if status.media_attachments.any?
        deliver_to_media(status)
      else
        deliver_to_nomedia(status)
      end
    end

    deliver_to_domain_subscribers(status)
    deliver_to_subscribers(status)
    deliver_to_subscribers_lists(status)

    return if status.reblog?

    deliver_to_hashtags(status)
  end

  private

  def deliver_to_self(status)
    Rails.logger.debug "Delivering status #{status.id} to author"
    FeedManager.instance.push_to_home(status.account, status)
  end

  def deliver_to_followers(status)
    Rails.logger.debug "Delivering status #{status.id} to followers"

    status.account.followers_for_local_distribution.select(:id).reorder(nil).find_in_batches do |followers|
      @feedInsertWorker.push_bulk(followers) do |follower|
        [status.id, follower.id, 'home']
      end
    end
  end

  def deliver_to_subscribers(status)
    Rails.logger.debug "Delivering status #{status.id} to subscribers"

    status.account.subscribers_for_local_distribution.with_reblog(status.reblog?).with_media(status.proper).select(:id, :account_id).reorder(nil).find_in_batches do |subscribings|
      @feedInsertWorker.push_bulk(subscribings) do |subscribing|
        [status.id, subscribing.account_id, 'home']
      end
    end
  end

  def deliver_to_subscribers_lists(status)
    Rails.logger.debug "Delivering status #{status.id} to subscribers lists"

    status.account.list_subscribers_for_local_distribution.with_reblog(status.reblog?).with_media(status.proper).select(:id, :list_id).reorder(nil).find_in_batches do |subscribings|
      @feedInsertWorker.push_bulk(subscribings) do |subscribing|
        [status.id, subscribing.list_id, 'list']
      end
    end
  end

  def deliver_to_domain_subscribers(status)
    Rails.logger.debug "Delivering status #{status.id} to domain subscribers"

    deliver_to_domain_subscribers_home(status)
    deliver_to_domain_subscribers_list(status)
  end

  def deliver_to_domain_subscribers_home(status)
    DomainSubscribe.domain_to_home(status.account.domain).with_reblog(status.reblog?).with_media(status.proper).select(:id, :account_id).find_in_batches do |subscribes|
      @feedInsertWorker.push_bulk(subscribes) do |subscribe|
        [status.id, subscribe.account_id, 'home']
      end
    end
  end

  def deliver_to_domain_subscribers_list(status)
    DomainSubscribe.domain_to_list(status.account.domain).with_reblog(status.reblog?).with_media(status.proper).select(:id, :list_id).find_in_batches do |subscribes|
      @feedInsertWorker.push_bulk(subscribes) do |subscribe|
        [status.id, subscribe.list_id, 'list']
      end
    end
  end

  def deliver_to_keyword_subscribers(status)
    return if status.reblog?

    deliver_to_keyword_subscribers_home(status)
    deliver_to_keyword_subscribers_list(status)
  end

  def deliver_to_keyword_subscribers_home(status)
    keyword_subscribes = KeywordSubscribe.active.with_media(status).without_local_followed_home(status.account).order(:account_id).merge(visibility_scope(status, KeywordSubscribe))
    match_ids          = keyword_subscribes.chunk(&:account_id).filter_map { |id, subscribes| id if subscribes.any? { |s| s.match?(status.searchable_text) } }

    @feedInsertWorker.push_bulk(match_ids) do |account_id|
      [status.id, account_id, 'home']
    end
  end

  def deliver_to_keyword_subscribers_list(status)
    keyword_subscribes = KeywordSubscribe.active.with_media(status).without_local_followed_list(status.account).order(:list_id).merge(visibility_scope(status, KeywordSubscribe))
    match_ids          = keyword_subscribes.chunk(&:list_id).filter_map { |id, subscribes| id if subscribes.any? { |s| s.match?(status.searchable_text) } }

    @feedInsertWorker.push_bulk(match_ids) do |list_id|
      [status.id, list_id, 'list']
    end
  end

  def visibility_scope(status, klass)
    if status.public_visibility? && !status.account.silenced?
      klass.all
    else
      scope = klass.where(account_id: status.account_id).or(klass.where(account_id: status.mentions.select(:account_id)))
      scope = scope.or(klass.where(account_id: status.account.followers.local.select(:id))) unless %w(limited direct).include?(status.visibility)
      scope
    end
  end

  def deliver_to_lists(status)
    Rails.logger.debug "Delivering status #{status.id} to lists"

    status.account.lists_for_local_distribution.select(:id).reorder(nil).find_in_batches do |lists|
      @feedInsertWorker.push_bulk(lists) do |list|
        [status.id, list.id, 'list']
      end
    end
  end

  def hide_direct_account_ids
    User.where(id: Setting.unscoped.where(thing_type: 'User', var: 'hide_direct_from_timeline', value: YAML.dump(true)).select(:thing_id)).select(:account_id)
  end

  def deliver_to_mentioned_followers(status)
    Rails.logger.debug "Delivering status #{status.id} to limited followers"

    mentions = status.mentions.joins(:account).merge(status.account.followers_for_local_distribution)
    mentions = mentions.where.not(account_id: hide_direct_account_ids) if status.direct_visibility?

    mentions.select(:id, :account_id).reorder(nil).find_in_batches do |mentions|
      @feedInsertWorker.push_bulk(mentions) do |mention|
        [status.id, mention.account_id, 'home']
      end
    end
  end

  def deliver_to_mentioned_lists(status)
    Rails.logger.debug "Delivering status #{status.id} to lists in limited followers"

    lists = status.account.lists_for_mentioned_local_distribution(status)
    lists = lists.where.not(account_id: hide_direct_account_ids) if status.direct_visibility?

    lists.select(:id).reorder(nil).find_in_batches do |lists|
      @feedInsertWorker.push_bulk(lists) do |list|
        [status.id, list.id, 'list']
      end
    end
  end

  def render_anonymous_payload(status)
    return @payload if defined?(@payload)

    @payload = attach_streaming_searchable_text(InlineRenderer.render(status, nil, :status), status)
    @payload = Oj.dump(event: :update, payload: @payload)
  end

  def render_anonymous_reblog_payload(status)
    return @reblog_payload if defined?(@reblog_payload)

    @reblog_payload = attach_streaming_searchable_text(InlineRenderer.render(status.reblog, nil, :status), status.reblog)
    @reblog_payload = Oj.dump(event: :update, payload: @reblog_payload)
  end

  def attach_streaming_searchable_text(payload, status)
    return payload unless payload.is_a?(Hash)

    payload[STREAMING_SEARCHABLE_TEXT_KEY] = status.proper.searchable_text
    payload
  end

  def deliver_to_hashtags(status)
    Rails.logger.debug "Delivering status #{status.id} to hashtags"

    status.tags_without_mute.pluck(:name).each do |hashtag|
      redis.publish("timeline:hashtag:#{hashtag.mb_chars.downcase}", @payload)
      redis.publish("timeline:hashtag:nobot:#{hashtag.mb_chars.downcase}", @payload) unless status.account.bot?
    end
  end

  def deliver_to_hashtag_followers(status)
    Rails.logger.debug "Delivering status #{status.id} to hashtag followers"

    deliver_to_hashtag_followers_home(status)
    deliver_to_hashtag_followers_list(status)
  end

  def deliver_to_hashtag_followers_home(status)
    @feedInsertWorker.push_bulk(FollowTag.home.where(tag: status.tags_without_mute).with_media(status.proper).merge(visibility_scope(status, FollowTag)).pluck(:account_id).uniq) do |follower|
      [status.id, follower, 'home']
    end
  end

  def deliver_to_hashtag_followers_list(status)
    @feedInsertWorker.push_bulk(FollowTag.list.where(tag: status.tags_without_mute).with_media(status.proper).merge(visibility_scope(status, FollowTag)).pluck(:list_id).uniq) do |list_id|
      [status.id, list_id, 'list']
    end
  end

  def deliver_to_group(status)
    Rails.logger.debug "Delivering status #{status.id} to group timeline"

    payload = status.reblog? ? @reblog_payload : @payload

    redis.publish("timeline:group:#{status.account.id}", payload)

    status.tags.pluck(:name).each do |hashtag|
      redis.publish("timeline:group:#{status.account.id}:#{hashtag.mb_chars.downcase}", payload)
    end

    if status.media_attachments.any?
      redis.publish("timeline:group:media:#{status.account.id}", payload)

      status.tags.pluck(:name).each do |hashtag|
        redis.publish("timeline:group:media:#{status.account.id}:#{hashtag.mb_chars.downcase}", payload)
      end
    else
      redis.publish("timeline:group:nomedia:#{status.account.id}", payload)

      status.tags.pluck(:name).each do |hashtag|
        redis.publish("timeline:group:nomedia:#{status.account.id}:#{hashtag.mb_chars.downcase}", payload)
      end
    end
  end

  def deliver_to_public(status)
    Rails.logger.debug "Delivering status #{status.id} to public timeline"

    redis.publish('timeline:public', @payload)
    redis.publish('timeline:public:nobot', @payload) unless status.account.bot?
    if status.local?
    else
      redis.publish('timeline:public:remote', @payload)
      redis.publish('timeline:public:remote:nobot', @payload) unless status.account.bot?
      redis.publish("timeline:public:domain:#{status.account.domain.mb_chars.downcase}", @payload)
      redis.publish("timeline:public:domain:nobot:#{status.account.domain.mb_chars.downcase}", @payload) unless status.account.bot?
    end
  end

  def deliver_to_index(status)
    redis.publish('timeline:index', @payload) if status.local? && status.public_searchability?
  end

  def deliver_to_media(status)
    Rails.logger.debug "Delivering status #{status.id} to media timeline"

    redis.publish('timeline:public:media', @payload)
    redis.publish('timeline:public:nobot:media', @payload) unless status.account.bot?
    if status.local?
    else
      redis.publish('timeline:public:remote:media', @payload)
      redis.publish('timeline:public:remote:nobot:media', @payload) unless status.account.bot?
      redis.publish("timeline:public:domain:media:#{status.account.domain.mb_chars.downcase}", @payload)
      redis.publish("timeline:public:domain:nobot:media:#{status.account.domain.mb_chars.downcase}", @payload) unless status.account.bot?
    end
  end

  def deliver_to_nomedia(status)
    Rails.logger.debug "Delivering status #{status.id} to no media timeline"

    redis.publish('timeline:public:nomedia', @payload)
    redis.publish('timeline:public:nobot:nomedia', @payload) unless status.account.bot?
    if status.local?
    else
      redis.publish('timeline:public:remote:nomedia', @payload)
      redis.publish('timeline:public:remote:nobot:nomedia', @payload) unless status.account.bot?
      redis.publish("timeline:public:domain:nomedia:#{status.account.domain.mb_chars.downcase}", @payload)
      redis.publish("timeline:public:domain:nobot:nomedia:#{status.account.domain.mb_chars.downcase}", @payload) unless status.account.bot?
    end
  end

  def deliver_to_own_conversation(status)
    AccountConversation.add_status(status.account, status)
  end

  def deliver_to_self_included_lists(status)
    @feedInsertWorker.push_bulk(status.account.self_included_lists.pluck(:id)) do |list_id|
      [status.id, list_id, 'list']
    end
  end
end
