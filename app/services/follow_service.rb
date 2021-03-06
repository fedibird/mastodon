# frozen_string_literal: true

class FollowService < BaseService
  include Redisable
  include Payloadable

  # Follow a remote user, notify remote user about the follow
  # @param [Account] source_account From which to follow
  # @param [String, Account] uri User URI to follow in the form of username@domain (or account record)
  # @param [Hash] options
  # @option [Boolean] :reblogs Whether or not to show reblogs, defaults to true
  # @option [Boolean] :bypass_locked
  # @option [Boolean] :with_rate_limit
  # @option [Boolean] :delivery
  def call(source_account, target_account, options = {})
    @source_account = source_account
    @target_account = ResolveAccountService.new.call(target_account, skip_webfinger: true)
    @options        = { reblogs: true, bypass_locked: false, with_rate_limit: false, delivery: true }.merge(options)

    raise ActiveRecord::RecordNotFound if following_not_possible?
    raise Mastodon::NotPermittedError  if following_not_allowed?

    if @source_account.following?(@target_account)
      UnmergeWorker.perform_async(@target_account.id, @source_account.id) if @source_account.delivery_following?(@target_account) && @options[:delivery]
      return change_follow_options!
    elsif @source_account.requested?(@target_account)
      return change_follow_request_options!
    end

    ActivityTracker.increment('activity:interactions')

    if (@target_account.locked? && !@options[:bypass_locked]) || @source_account.silenced? || @target_account.activitypub?
      request_follow!
    elsif @target_account.local?
      direct_follow!
    end
  end

  private

  def following_not_possible?
    @target_account.nil? || @target_account.id == @source_account.id || @target_account.suspended?
  end

  def following_not_allowed?
    @target_account.blocking?(@source_account) || @source_account.blocking?(@target_account) || @target_account.moved? || (!@target_account.local? && @target_account.ostatus?) || @source_account.domain_blocking?(@target_account.domain)
  end

  def change_follow_options!
    @source_account.follow!(@target_account, reblogs: @options[:reblogs], delivery: @options[:delivery])
  end

  def change_follow_request_options!
    @source_account.request_follow!(@target_account, reblogs: @options[:reblogs], delivery: @options[:delivery])
  end

  def request_follow!
    follow_request = @source_account.request_follow!(@target_account, reblogs: @options[:reblogs], delivery: @options[:delivery], rate_limit: @options[:with_rate_limit])

    if @target_account.local?
      LocalNotificationWorker.perform_async(@target_account.id, follow_request.id, follow_request.class.name)
    elsif @target_account.activitypub?
      ActivityPub::DeliveryWorker.perform_async(build_json(follow_request), @source_account.id, @target_account.inbox_url)
    end

    follow_request
  end

  def direct_follow!
    follow = @source_account.follow!(@target_account, reblogs: @options[:reblogs], delivery: @options[:delivery], rate_limit: @options[:with_rate_limit])

    LocalNotificationWorker.perform_async(@target_account.id, follow.id, follow.class.name)
    MergeWorker.perform_async(@target_account.id, @source_account.id) if @options[:delivery]

    follow
  end

  def build_json(follow_request)
    Oj.dump(serialize_payload(follow_request, ActivityPub::FollowSerializer))
  end
end
