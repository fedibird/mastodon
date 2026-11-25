# frozen_string_literal: true

module PostDrafts
  # WebUI server sync is off until an operator turns it on. Administrators
  # are admitted while it is on. Everyone else needs an explicit user id.
  # This does not change the post-draft API for an OAuth token that already
  # asked for the scopes, and it does not add those scopes to external apps.
  module Feature
    module_function

    def enabled?
      ActiveModel::Type::Boolean.new.cast(Setting.post_draft_sync)
    end

    def permitted?(user)
      enabled? && user.present? && (administrator?(user) || tester?(user))
    end

    def administrator?(user)
      user.present? && user.can?(:administrator)
    end

    def tester?(user)
      user.present? && tester_ids.include?(user.id.to_i)
    end

    def tester_ids
      Setting.post_draft_sync_testers.to_s.split(/[,\s]+/).filter_map do |part|
        Integer(part, 10)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
