# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Instance kill switch plus a default-deny tester allowlist.
    # Setting.external_bridge_atproto must be true, and the user's id must be
    # listed in Setting.external_bridge_atproto_testers. An empty list admits
    # nobody. Turning the flag off does not delete stored identity metadata.
    module Feature
      module_function

      def enabled?
        ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_atproto)
      end

      def permitted?(user)
        enabled? && tester?(user)
      end

      def tester?(user)
        user.present? && tester_ids.include?(user.id.to_i)
      end

      def tester_ids
        Setting.external_bridge_atproto_testers.to_s.split(/[,\s]+/).filter_map do |part|
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
