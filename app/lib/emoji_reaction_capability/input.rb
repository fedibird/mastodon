# frozen_string_literal: true

module EmojiReactionCapability
  Input = Data.define(:viewer, :status, :node, :counts, :site) do
    def initialize(status:, node:, viewer: Viewer.new, counts: Counts.unavailable, site: SiteLimits.new)
      super
    end
  end
end
