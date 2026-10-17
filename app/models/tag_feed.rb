# frozen_string_literal: true

class TagFeed < PublicFeed
  LIMIT_PER_MODE = 4

  # @param [Tag] tag
  # @param [Account] account
  # @param [Hash] options
  # @option [Enumerable<String>] :any
  # @option [Enumerable<String>] :all
  # @option [Enumerable<String>] :none
  # @option [Boolean] :local
  # @option [Boolean] :remote
  # @option [Boolean] :only_media
  # @option [Boolean] :without_media
  # @option [Boolean] :without_bot
  def initialize(tag, account, options = {})
    @tag = tag
    super(account, options)
  end

  # @param [Integer] limit
  # @param [Integer] max_id
  # @param [Integer] since_id
  # @param [Integer] min_id
  # @return [Array<Status>]
  def get(limit, max_id = nil, since_id = nil, min_id = nil)
    relation.to_a_paginated_by_id(limit, max_id: max_id, since_id: since_id, min_id: min_id)
  end

  def relation
    scope = public_scope

    scope.merge!(tag_account_mute_scope)
    scope.merge!(tagged_with_any_scope)
    scope.merge!(tagged_with_all_scope)
    scope.merge!(tagged_with_none_scope)
    scope.merge!(remote_only_scope) if remote_only?
    scope.merge!(account_filters_scope) if account?
    scope.merge!(media_only_scope) if media_only?
    scope.merge!(without_media_scope) if without_media?
    scope.merge!(without_bot_scope) if without_bot?

    scope
  end

  private

  def tag_account_mute_scope
    Status.where.not(account: @tag.mute_accounts)
  end

  def tagged_with_any_scope
    Status.group(:id).tagged_with(tags_for(Array(@tag.name) | Array(options[:any])))
  end

  def tagged_with_all_scope
    Status.group(:id).tagged_with_all(tags_for(options[:all]))
  end

  def tagged_with_none_scope
    Status.group(:id).tagged_with_none(tags_for(options[:none]))
  end

  def tags_for(names)
    Tag.matching_name(Array(names).take(LIMIT_PER_MODE)).pluck(:id) if names.present?
  end
end
