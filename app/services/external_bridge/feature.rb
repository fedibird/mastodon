# frozen_string_literal: true

module ExternalBridge
  # Instance flag. Default false. Testers opt in with
  # `Setting.external_bridge_rss = true` in a Rails console.
  # That enables fetch and subscribe for the instance. It does not
  # make an existing projection readable by anyone except its user.
  module Feature
    def self.enabled?
      ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_rss)
    end
  end
end
