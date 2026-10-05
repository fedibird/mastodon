# frozen_string_literal: true

class PublicFeed
  # @param [Account] account
  # @param [Hash] options
  # @option [Boolean] :with_replies
  # @option [Boolean] :with_reblogs
  # @option [Boolean] :local
  # @option [Boolean] :remote
  # @option [Boolean] :only_media
  # @option [Boolean] :without_media
  # @option [Boolean] :without_bot
  # @option [String] :domain
  def initialize(account, options = {})
    @account = account
    @options = options
  end

  # @param [Integer] limit
  # @param [Integer] max_id
  # @param [Integer] since_id
  # @param [Integer] min_id
  # @return [Array<Status>]
  def get(limit, max_id = nil, since_id = nil, min_id = nil)
    return Status.none if local_only? && !imast? && !mastodon_for_ios? && !mastodon_for_android?
    return Status.none if domain_only? && !domain_available?

    scope = public_scope

    scope.merge!(without_replies_scope) unless with_replies?
    scope.merge!(without_reblogs_scope) unless with_reblogs?
    scope.merge!(local_only_scope) if index_only? && !account?
    scope.merge!(public_searchable_scope) if index_only? && !account?
    scope.merge!(remote_only_scope) if remote_only?
    scope.merge!(domain_only_scope) if domain_only?
    scope.merge!(account_filters_scope) if account?
    scope.merge!(media_only_scope) if media_only?
    scope.merge!(without_media_scope) if without_media?
    scope.merge!(without_bot_scope) if without_bot?

    scope.to_a_paginated_by_id(limit, max_id: max_id, since_id: since_id, min_id: min_id)
  end

  private

  attr_reader :account, :options

  def with_reblogs?
    options[:with_reblogs]
  end

  def with_replies?
    options[:with_replies]
  end

  def index_only?
    options[:index]
  end

  def local_only?
    options[:local]
  end

  def imast?
    options[:application]&.website == 'https://cinderella-project.github.io/iMast/'
  end

  def mastodon_for_ios?
    options[:application]&.name == 'Mastodon for iOS'
  end

  def mastodon_for_android?
    options[:application]&.name == 'Mastodon for Android'
  end

  def remote_only?
    options[:remote]
  end

  def domain_only?
    options[:domain]
  end

  def account?
    account.present?
  end

  def media_only?
    options[:only_media]
  end

  def without_media?
    options[:without_media]
  end

  def without_bot?
    options[:without_bot]
  end

  def domain
    return @domain if defined?(@domain)

    raw_domain = options[:domain]
    @domain = raw_domain.present? ? TagManager.instance.normalize_domain(raw_domain.to_s.strip) : nil
  rescue Addressable::URI::InvalidURIError
    @domain = nil
  end

  def domain_available?
    domain.present? && Account.where(domain: domain).without_suspended.without_silenced.exists?
  end

  def public_scope
    Status.with_public_visibility.joins(:account).merge(Account.without_suspended.without_silenced)
  end

  def local_only_scope
    Status.local
  end

  def public_searchable_scope
    Status.where(searchability: 'public').or(Status.where(searchability: nil).merge(Account.where(searchability: 'public')))
  end

  def remote_only_scope
    Status.remote
  end

  def domain_only_scope
    Status.joins(:account).merge(Account.where(domain: domain))
  end

  def without_replies_scope
    Status.without_replies
  end

  def without_reblogs_scope
    Status.without_reblogs
  end

  def media_only_scope
    Status.joins(:media_attachments).group(:id)
  end

  def without_media_scope
    Status.left_joins(:media_attachments).where(media_attachments: {status_id: nil})
  end

  def without_bot_scope
    Status.joins(:account).merge(Account.without_bots)
  end

  def account_filters_scope
    Status.not_excluded_by_account(account).tap do |scope|
      scope.merge!(Status.not_domain_blocked_by_account(account)) unless local_only?
      scope.merge!(Status.in_chosen_languages(account)) if account.chosen_languages.present?
    end
  end
end
