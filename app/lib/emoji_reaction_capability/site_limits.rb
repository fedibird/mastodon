# frozen_string_literal: true

module EmojiReactionCapability
  # Local site facts. local_max is the per-account cap this server enforces; it
  # is never a statement about a remote Node. nil means "not read".
  SiteLimits = Data.define(:local_max) do
    def initialize(local_max: nil)
      super
    end
  end
end
