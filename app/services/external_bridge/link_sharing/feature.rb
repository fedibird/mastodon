# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # E4-A kill switch. Independent of RSS, AT Protocol, the E2 storage
    # switch, and E3 delivery. Off does not delete a policy or a reference
    # note. An empty tester list admits nobody.
    module Feature
      module_function

      def enabled?
        ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_link_sharing)
      end

      def permitted?(user)
        enabled? && tester?(user)
      end

      def tester?(user)
        user.present? && tester_ids.include?(user.id.to_i)
      end

      def tester_ids
        Setting.external_bridge_link_sharing_testers.to_s.split(/[,\s]+/).filter_map do |part|
          Integer(part, 10)
        rescue ArgumentError, TypeError
          nil
        end
      end

      def require!(user)
        raise Error, :feature_disabled unless enabled?
        raise Error, :tester_only unless tester?(user)
      end
    end
  end
end
