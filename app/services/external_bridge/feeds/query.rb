# frozen_string_literal: true

module ExternalBridge
  module Feeds
    # Read-only status ids for one user and one home or list destination.
    # The relation is the membership snapshot. It is not cached across
    # requests. Pause, error, and the RSS fetch flag are not filters.
    class Query
      HOME = 'home'
      LIST = 'list'

      def self.scope_for(user:, destination:, list: nil)
        new(user: user, destination: destination, list: list).scope
      end

      def initialize(user:, destination:, list: nil)
        @user = user
        @destination = destination.to_s
        @list = list
      end

      def scope
        return ExternalStatusProjection.none unless readable?

        relation = ExternalStatusProjection.joins(membership_joins)
        relation = relation.where(external_status_projections: { user_id: @user.id, source_deleted: false })
        relation = relation.where(status_shape_sql)
        relation = relation.where('users.account_id = external_status_projections.account_id')
        relation = relation.where('statuses.account_id = external_status_projections.account_id')
        relation = relation.where('statuses.reply IS NOT TRUE')
        relation = relation.where('statuses.deleted_at IS NULL')
        relation = relation.where('statuses.expired_at IS NULL')
        apply_destination(relation)
      end

      def ids(limit:, ascending: false, lower_exclusive: nil, upper_exclusive: nil, lower_inclusive: nil, upper_inclusive: nil)
        return [] unless readable?

        width = clamp(limit)
        return [] if width.zero?

        bounded = apply_bounds(scope, lower_exclusive, upper_exclusive, lower_inclusive, upper_inclusive)
        direction = ascending ? 'ASC' : 'DESC'
        relation = bounded.reselect('statuses.id').distinct.order(Arel.sql("statuses.id #{direction}")).limit(width)
        read_ids(relation)
      end

      def eligible_ids(status_ids)
        return [] unless readable?

        wanted = Array(status_ids).filter_map { |value| integer_id(value) }.uniq
        return [] if wanted.empty?

        relation = scope.where(statuses: { id: wanted }).reselect('statuses.id').distinct
        read_ids(relation)
      end

      private

      def readable?
        @user.present? &&
          Feature.permitted?(@user) &&
          (destination_home? || destination_list?) &&
          list_owned?
      end

      def destination_home?
        @destination == HOME
      end

      def destination_list?
        @destination == LIST
      end

      def list_owned?
        return true if destination_home?

        @list.present? && @list.account_id.present? && @list.account_id == @user.account_id
      end

      def membership_joins
        <<~SQL.squish
          INNER JOIN statuses
            ON statuses.id = external_status_projections.status_id
          INNER JOIN users
            ON users.id = external_status_projections.user_id
          INNER JOIN external_subscriptions
            ON external_subscriptions.id = external_status_projections.external_subscription_id
           AND external_subscriptions.user_id = external_status_projections.user_id
           AND external_subscriptions.external_source_id = external_status_projections.external_source_id
          INNER JOIN external_resources
            ON external_resources.id = external_status_projections.external_resource_id
           AND external_resources.external_source_id = external_status_projections.external_source_id
          INNER JOIN external_feed_routes
            ON external_feed_routes.external_subscription_id = external_status_projections.external_subscription_id
           AND external_feed_routes.user_id = external_status_projections.user_id
        SQL
      end

      def status_shape_sql
        {
          statuses: {
            visibility: Status.visibilities[:external],
            external_projection: true,
            local: true,
            uri: nil,
            searchability: Status.searchabilities[:personal],
            reblog_of_id: nil,
            in_reply_to_id: nil,
            quote_id: nil,
          },
        }
      end

      def apply_destination(relation)
        if destination_home?
          relation.where(external_feed_routes: { destination: HOME, list_id: nil })
        else
          relation.where(external_feed_routes: { destination: LIST, list_id: @list.id }).where(<<~SQL.squish)
            EXISTS (
              SELECT 1 FROM lists route_lists
              WHERE route_lists.id = external_feed_routes.list_id
                AND route_lists.account_id = users.account_id
            )
          SQL
        end
      end

      def apply_bounds(relation, lower_exclusive, upper_exclusive, lower_inclusive, upper_inclusive)
        relation = relation.where('statuses.id > ?', lower_exclusive) unless lower_exclusive.nil?
        relation = relation.where('statuses.id < ?', upper_exclusive) unless upper_exclusive.nil?
        relation = relation.where('statuses.id >= ?', lower_inclusive) unless lower_inclusive.nil?
        relation = relation.where('statuses.id <= ?', upper_inclusive) unless upper_inclusive.nil?
        relation
      end

      def clamp(limit)
        value = limit.to_i
        return 0 if value <= 0

        [value, FeedManager::MAX_ITEMS].min
      end

      def read_ids(relation)
        ActiveRecord::Base.connection.select_values(relation.to_sql).map { |value| Integer(value) }
      end

      def integer_id(value)
        text = value.to_s
        return nil unless text.match?(/\A[1-9]\d*\z/)

        Integer(text, 10)
      end
    end
  end
end
