# frozen_string_literal: true

module ExternalBridge
  module Feeds
    # Delivery switch for home and list. Independent of RSS fetch, AT Protocol
    # connection, and the E2 storage switch. Off does not delete routes or
    # projections. An empty tester list admits nobody.
    module Feature
      module_function

      def enabled?
        ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_feeds)
      end

      def permitted?(user)
        enabled? && tester?(user)
      end

      def tester?(user)
        user.present? && tester_ids.include?(user.id.to_i)
      end

      def tester_ids
        Setting.external_bridge_feeds_testers.to_s.split(/[,\s]+/).filter_map do |part|
          Integer(part, 10)
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
