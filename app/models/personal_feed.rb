# frozen_string_literal: true

class PersonalFeed
  # @param [Account] account
  # @param [Hash] options
  # @option [Boolean] :only_media
  # @option [Boolean] :without_media
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
    relation.to_a_paginated_by_id(limit, max_id: max_id, since_id: since_id, min_id: min_id)
  end

  def relation
    scope = personal_scope

    scope.merge!(media_only_scope) if media_only?
    scope.merge!(without_media_scope) if without_media?

    scope
  end

  private

  attr_reader :account, :options

  def media_only?
    options[:only_media]
  end

  def without_media?
    options[:without_media]
  end

  def media_only_scope
    Status.joins(:media_attachments).group(:id)
  end

  def without_media_scope
    Status.left_joins(:media_attachments).where(media_attachments: { status_id: nil })
  end

  def personal_scope
    Status.include_expired.where(account_id: account.id).without_reblogs.with_personal_visibility
  end
end
