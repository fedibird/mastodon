# frozen_string_literal: true

# Future hook: may this import run at all? PR B defaults to true and does
# not read moderation, Follow Gate, or risk. Pacing stays independent of
# why an import might later be paused.
module FollowImport
  class Eligibility
    def self.executable?(_batch)
      true
    end
  end
end
