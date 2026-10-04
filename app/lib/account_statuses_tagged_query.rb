# frozen_string_literal: true

# ID-first intersection for GET /api/v1/accounts/:account_id/statuses?tagged=
#
# A large account and a large tag can each match tens of thousands of
# statuses while sharing only a few. Selecting statuses.* in that join
# makes the planner walk one side and either read the wide status heap
# or probe the other side once per candidate, before the sparse
# intersection is known.
#
# The caller supplies the existing permission relation. This query keeps
# the intersection on status ids and marks the CTE MATERIALIZED so the
# planner does not fold it back into that wide join. statuses.* is read
# only for the ids that survive.
#
# exclude_replies and exclude_reblogs are API filters, separate from the
# reblog visibility already present on the permission relation. They are
# applied after the intersection and before LIMIT: the reply predicate
# in particular is an OR across columns the id intersection does not
# need. Pagination bounds are id predicates, so they stay inside the CTE.
# min_id matches Paginable#paginate_by_min_id: the next page is taken in
# ascending id order and then reversed. since_id is ignored when min_id
# is present, as to_a_paginated_by_id does.
class AccountStatusesTaggedQuery
  def initialize(candidate_scope:, tag_id:, limit:, page: {}, filters: {})
    @candidate_scope = candidate_scope
    @tag_id = Integer(tag_id)
    @limit = normalize_limit(limit)
    @max_id = normalize_bound(page_value(page, :max_id))
    @since_id = normalize_bound(page_value(page, :since_id))
    @min_id = normalize_bound(page_value(page, :min_id))
    @exclude_replies = truthy_filter?(filters, :exclude_replies)
    @exclude_reblogs = truthy_filter?(filters, :exclude_reblogs)
  end

  def records
    rows = Status.find_by_sql(to_sql)
    @min_id.nil? ? rows : rows.reverse
  end

  def to_sql
    [
      "WITH matched_ids AS MATERIALIZED (#{matched_ids_scope.to_sql})",
      'SELECT statuses.*',
      'FROM statuses',
      'INNER JOIN matched_ids ON matched_ids.id = statuses.id',
      outer_where_sql,
      order_sql,
      "LIMIT #{@limit}",
    ].compact.join(' ')
  end

  private

  def matched_ids_scope
    # Drop eager loads and any limit/order carried by the permission
    # relation. The page size is applied only after the outer filters.
    scope = @candidate_scope
            .except(:includes, :preload, :eager_load)
            .unscope(:limit, :offset)
            .reorder(nil)
            .reselect(Status.arel_table[:id])
            .joins(:statuses_tags)
            .where(statuses_tags: { tag_id: @tag_id })

    apply_page_bounds(scope)
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

  def outer_where_sql
    predicates = []
    predicates << scope_predicate(Status.unscoped.without_replies) if @exclude_replies
    predicates << scope_predicate(Status.unscoped.without_reblogs) if @exclude_reblogs
    return if predicates.empty?

    "WHERE #{predicates.map { |predicate| "(#{predicate})" }.join(' AND ')}"
  end

  def scope_predicate(relation)
    sql = relation.reselect(Arel.sql('1')).reorder(nil).to_sql
    predicate = sql.split(/\bWHERE\b/, 2).last
    raise ArgumentError, "scope has no predicate: #{sql}" if predicate.blank?

    predicate.strip
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
