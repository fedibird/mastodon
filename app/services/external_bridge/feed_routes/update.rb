# frozen_string_literal: true

module ExternalBridge
  module FeedRoutes
    # Replaces the route set for one subscription owned by the authenticated
    # user. The subscription row is locked, the whole set is checked, then
    # the difference is written. A no-op does not move the revision or
    # updated_at. A stale revision writes nothing.
    class Update
      MAX_LISTS = List::PER_ACCOUNT_LIMIT

      def call(user:, subscription_id:, home:, list_ids:, expected_revision:)
        raise Error, :not_found if user.nil?

        home_flag = coerce_home(home)
        desired_lists = coerce_list_ids(list_ids)
        revision = coerce_revision(expected_revision)
        subscription = owned_subscription(user, subscription_id)

        ExternalSubscription.transaction do
          subscription.lock!
          raise Error, :stale_feed_routes if subscription.feed_routes_revision.to_i != revision

          assert_lists_owned!(user, desired_lists)
          current = subscription.external_feed_routes.to_a
          return subscription if same?(home_flag, desired_lists, current)

          assert_additions_allowed!(user, home_flag, desired_lists, current)
          apply!(user, subscription, home_flag, desired_lists, current)
          subscription.update_columns(
            feed_routes_revision: subscription.feed_routes_revision.to_i + 1,
            updated_at: Time.current
          )
        end
        subscription.reload
      rescue ActiveRecord::RecordNotFound
        raise Error, :not_found
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid
        raise Error, :invalid_feed_route
      end

      private

      def owned_subscription(user, subscription_id)
        found = ExternalSubscription.find_by(id: coerce_record_id(subscription_id), user_id: user.id)
        raise Error, :not_found if found.nil?

        found
      end

      def coerce_record_id(value)
        text = value.to_s
        raise Error, :not_found unless text.match?(/\A[1-9]\d*\z/)

        Integer(text, 10)
      end

      def coerce_home(value)
        case value
        when true, false then value
        when '1', 'true', 'on' then true
        when '0', 'false', 'off' then false
        else raise Error, :invalid_feed_route
        end
      end

      def coerce_list_ids(value)
        raise Error, :invalid_feed_route unless value.is_a?(Array)
        raise Error, :invalid_feed_route if value.length > MAX_LISTS + 1

        ids = value.filter_map do |item|
          text = item.to_s
          next if text.empty?
          raise Error, :invalid_feed_route unless text.match?(/\A[1-9]\d*\z/)

          Integer(text, 10)
        end
        ids.uniq!
        raise Error, :invalid_feed_route if ids.length > MAX_LISTS

        ids.sort
      end

      def coerce_revision(value)
        text = value.to_s
        raise Error, :invalid_feed_route unless text.match?(/\A\d+\z/)

        Integer(text, 10)
      end

      def assert_lists_owned!(user, list_ids)
        return if list_ids.empty?

        owned = List.where(id: list_ids, account_id: user.account_id).pluck(:id).sort
        raise Error, :invalid_feed_route if owned != list_ids
      end

      def same?(home, list_ids, current)
        current_home = current.any? { |route| route.destination == 'home' }
        current_lists = current.select { |route| route.destination == 'list' }.map(&:list_id).sort
        current_home == home && current_lists == list_ids
      end

      def assert_additions_allowed!(user, home, list_ids, current)
        return if Feeds::Feature.permitted?(user)

        current_home = current.any? { |route| route.destination == 'home' }
        current_lists = current.select { |route| route.destination == 'list' }.map(&:list_id)
        adding_home = home && !current_home
        adding_lists = list_ids - current_lists
        raise Error, :feed_routes_disabled if adding_home || adding_lists.any?
      end

      def apply!(user, subscription, home, list_ids, current)
        home_route = current.find { |route| route.destination == 'home' }
        if home && home_route.nil?
          create_route!(user, subscription, 'home', nil)
        elsif !home && home_route
          home_route.destroy!
        end

        listed = current.select { |route| route.destination == 'list' }
        listed.each { |route| route.destroy! unless list_ids.include?(route.list_id) }
        (list_ids - listed.map(&:list_id)).each do |list_id|
          create_route!(user, subscription, 'list', list_id)
        end
      end

      def create_route!(user, subscription, destination, list_id)
        ExternalFeedRoute.create!(
          user_id: user.id,
          external_subscription_id: subscription.id,
          destination: destination,
          list_id: list_id
        )
      end
    end
  end
end
