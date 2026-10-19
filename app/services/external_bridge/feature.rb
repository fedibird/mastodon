# frozen_string_literal: true

module ExternalBridge
  # Instance kill switch plus a default-deny tester allowlist.
  # Setting.external_bridge_rss must be true, and the user's id must be
  # listed in Setting.external_bridge_rss_testers. An empty list admits
  # nobody. Neither switch makes an existing projection readable by
  # anyone except its owning user.
  module Feature
    module_function

    def enabled?
      ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_rss)
    end

    def permitted?(user)
      enabled? && tester?(user)
    end

    def tester?(user)
      user.present? && tester_ids.include?(user.id.to_i)
    end

    def tester_ids
      Setting.external_bridge_rss_testers.to_s.split(/[,\s]+/).filter_map do |part|
        Integer(part, 10)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
