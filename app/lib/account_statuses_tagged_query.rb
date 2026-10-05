# frozen_string_literal: true

# ID-first intersection of one account's statuses with one tag.
#
# Used by GET /api/v1/accounts/:account_id/statuses?tagged= and by the
# public profile page /@:username/tagged/:tag (including its older/newer
# probes). A large account and a large tag can each match tens of
# thousands of statuses while sharing only a few. Selecting statuses.*
# in that join makes the planner walk one side and either read the wide
# status heap or probe the other side once per candidate, before the
# sparse intersection is known.
#
# The caller supplies the candidate relation. The API passes its
# permission scope. The public profile passes public and unlisted
# statuses only, which is the HTML page's existing visibility rule.
#
# By default, and for the REST API, exclude_replies and exclude_reblogs
# are applied inside the materialized CTE, before ORDER BY statuses.id
# and LIMIT. The outer query only hydrates statuses.* for those ids.
#
# filter_after_intersection keeps those predicates out of the CTE.
# The CTE is the ordered account/tag intersection, including page
# bounds. Hydration, the reply and reblog predicates, and LIMIT run on
# the outer query. Reply columns are not in the account/tag index, so
# applying that predicate during the candidate scan can read the status
# heap once per candidate. The outer LIMIT can stop CTE evaluation once
# the page is full; the CTE does not have to emit every matching id.
# The public profile uses this option. This does not promise a
# particular PostgreSQL plan.
#
# PostgreSQL 12 and newer inline a CTE unless it is marked MATERIALIZED.
# PostgreSQL 10 and 11 always materialize CTEs and reject that keyword,
# so the same shape is written as a plain CTE there.
#
# min_id matches Paginable#paginate_by_min_id: the next page is taken in
# ascending id order and then reversed. since_id is ignored when min_id
# is present, as to_a_paginated_by_id does.
class AccountStatusesTaggedQuery
  # PostgreSQL 12.0. Earlier servers materialize every CTE and do not
  # accept AS MATERIALIZED.
  MATERIALIZED_CTE_VERSION = 120_000

  def self.materialization_keyword(database_version)
    database_version >= MATERIALIZED_CTE_VERSION ? 'MATERIALIZED ' : ''
  end

  def initialize(candidate_scope:, tag_id:, limit:, page: {}, filters: {}, filter_after_intersection: false) # rubocop:disable Metrics/ParameterLists
    @candidate_scope = candidate_scope
    @tag_id = Integer(tag_id)
    @limit = normalize_limit(limit)
    @max_id = normalize_bound(page_value(page, :max_id))
    @since_id = normalize_bound(page_value(page, :since_id))
    @min_id = normalize_bound(page_value(page, :min_id))
    @exclude_replies = truthy_filter?(filters, :exclude_replies)
    @exclude_reblogs = truthy_filter?(filters, :exclude_reblogs)
    @filter_after_intersection = filter_after_intersection
  end

  def records
    rows = Status.find_by_sql(to_sql)
    @min_id.nil? ? rows : rows.reverse
  end

  def to_sql
    parts = [
      "WITH matched_ids AS #{materialization_keyword}(#{matched_ids_scope.to_sql})",
      'SELECT statuses.*',
      'FROM statuses',
      'INNER JOIN matched_ids ON matched_ids.id = statuses.id',
    ]
    parts << outer_filter_sql if outer_filter_sql
    parts << order_sql
    parts << "LIMIT #{@limit}" if @filter_after_intersection
    parts.join(' ')
  end

  private

  def materialization_keyword
    self.class.materialization_keyword(Status.connection.database_version)
  end

  def matched_ids_scope
    # Drop eager loads and any limit/order carried by the candidate
    # relation. Default mode applies the caller filters and LIMIT here.
    # filter_after_intersection leaves those to the outer query so the
    # CTE can stay an account/tag id intersection.
    scope = @candidate_scope
            .except(:includes, :preload, :eager_load)
            .unscope(:limit, :offset)
            .reorder(nil)
            .joins(:statuses_tags)
            .where(statuses_tags: { tag_id: @tag_id })
    unless @filter_after_intersection
      scope = scope.merge(Status.unscoped.without_replies) if @exclude_replies
      scope = scope.merge(Status.unscoped.without_reblogs) if @exclude_reblogs
    end
    scope = apply_page_bounds(scope)
    scope = scope.reselect(Status.arel_table[:id]).reorder(id_order)
    scope = scope.limit(@limit) unless @filter_after_intersection
    scope
  end

  def outer_filter_sql
    return unless @filter_after_intersection

    clauses = []
    # Parentheses keep OR from binding more loosely than a following AND.
    clauses << '(statuses.reply = FALSE OR statuses.in_reply_to_account_id = statuses.account_id)' if @exclude_replies
    clauses << 'statuses.reblog_of_id IS NULL' if @exclude_reblogs
    return if clauses.empty?

    "WHERE #{clauses.join(' AND ')}"
  end

  def id_order
    column = Status.arel_table[:id]
    @min_id.nil? ? column.desc : column.asc
  end

  def apply_page_bounds(scope)
    id_column = Status.arel_table[:id]
    scope = scope.where(id_column.lt(@max_id)) unless @max_id.nil?
    scope = scope.where(id_column.gt(lower_id_bound)) unless lower_id_bound.nil?
    scope
  end

  def lower_id_bound
    @min_id.nil? ? @since_id : @min_id
  end

  def order_sql
    direction = @min_id.nil? ? 'DESC' : 'ASC'
    "ORDER BY statuses.id #{direction}"
  end

  def page_value(page, key)
    return if page.blank?

    value = page[key]
    value.nil? ? page[key.to_s] : value
  end

  def truthy_filter?(filters, key)
    return false if filters.blank?

    value = filters[key]
    value = filters[key.to_s] if value.nil?
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def normalize_limit(value)
    limit = Integer(value)
    raise ArgumentError, 'limit must be a non-negative integer' if limit.negative?

    limit
  end

  def normalize_bound(value)
    return if value.blank?

    Integer(value)
  end
end
