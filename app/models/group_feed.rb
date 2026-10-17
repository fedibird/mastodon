# frozen_string_literal: true

class GroupFeed < PublicFeed
  # @param [Account] group
  # @param [Account] account
  # @param [Hash] options
  # @option [Boolean] :only_media
  # @option [Boolean] :without_media
  # @option [Boolean] :without_bot
  # @option [String] :tagged
  def initialize(group, account, options = {})
    @group = group
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
    scope = group_scope

    scope.merge!(media_only_scope) if media_only?
    scope.merge!(without_media_scope) if without_media?
    scope.merge!(without_bot_scope) if without_bot?
    scope.merge!(hashtag_scope) if tagged?

    scope
  end

  private

  attr_reader :group

  def tagged?
    options[:tagged]
  end

  def group_scope
    group.permitted_group_statuses(account).joins(:account).merge(Account.without_suspended)
  end

  def hashtag_scope
    tag = Tag.find_normalized(options[:tagged])

    if tag
      Status.tagged_with(tag.id)
    else
      Status.none
    end
  end
end
