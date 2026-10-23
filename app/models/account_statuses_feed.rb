# frozen_string_literal: true

# Account timeline scope shared by GET /api/v1/accounts/:account_id/statuses
# and account-source seek. Paging stays on the controller. Seek membership is
# a point lookup: account_id and id together, LIMIT 1, not a walk of the account.
#
# viewer_filters is seek-only. The profile request does not drop muted or
# blocked-by-the-viewer rows, and this feed does not start doing that for it.
class AccountStatusesFeed
  def initialize(account, viewer, options = {})
    @account = account
    @viewer = viewer
    @options = options
  end

  def permission_scope
    scope = account.permitted_statuses(viewer).merge(Status.include_expired.without_link_boost_wrappers)
    scope = scope.merge(Status.include_expired.without_personal_visibility) if hide_personal?
    scope
  end

  def relation
    scope = permission_scope
    scope = scope.merge(only_media_scope) if only_media?
    scope = scope.merge(Status.include_expired.without_replies) if exclude_replies?
    scope = scope.merge(Status.include_expired.without_reblogs) if exclude_reblogs?
    scope = scope.merge(tagged_scope) if tagged?
    scope = apply_viewer_filters(scope) if viewer_filters?
    scope
  end

  # Equality on (account_id, id) plus LIMIT. Neighbor pages use the account
  # statuses API, which already bounds max_id / min_id.
  def contains_id?(status_id)
    return false if status_id.nil? || account.nil? || account.suspended?

    point_relation(status_id).pick(Status.arel_table[:id]) == status_id.to_i
  end

  def scope_ids(status_ids, limit:)
    ids = Array(status_ids).first(limit)
    return [] if ids.empty? || account.nil? || account.suspended?

    point_base.where(statuses: { id: ids }).limit(limit).pluck(Status.arel_table[:id])
  end

  def remote_account?
    account.domain.present?
  end

  def point_relation(status_id)
    point_base.where(statuses: { id: status_id }).limit(1)
  end

  private

  attr_reader :account, :viewer, :options

  def point_base
    relation.except(:includes, :preload, :eager_load).unscope(:order, :limit, :offset).where(statuses: { account_id: account.id })
  end

  def apply_viewer_filters(scope)
    return scope if viewer.nil? || viewer.id == account.id

    scope = scope.merge(Status.not_excluded_by_account(viewer))
    return scope unless account.domain.present? && viewer.excluded_from_timeline_domains.present?

    scope.merge(Status.not_domain_blocked_by_account(viewer))
  end

  def only_media_scope
    Status.include_expired.joins(:media_attachments).merge(account.media_attachments.reorder(nil)).distinct
  end

  def tagged_scope
    return Status.none if options[:tag_missing]

    tag = Tag.find_normalized(options[:tagged])
    return Status.none if tag.nil?

    Status.include_expired.tagged_with(tag.id)
  end

  def tagged?
    options[:tagged].present? || options[:tag_missing]
  end

  def exclude_replies?
    truthy?(:exclude_replies)
  end

  def exclude_reblogs?
    truthy?(:exclude_reblogs)
  end

  def only_media?
    truthy?(:only_media)
  end

  def hide_personal?
    truthy?(:hide_personal)
  end

  def viewer_filters?
    truthy?(:viewer_filters)
  end

  def truthy?(key)
    ActiveModel::Type::Boolean.new.cast(options[key])
  end
end
