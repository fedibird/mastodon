# frozen_string_literal: true

# May this import run at all? Ready-only: screening, review_required,
# and stopped batches are not executable. Pacing stays independent of
# why a batch is held. This is not a risk score or moderation verdict.
module FollowImport
  class Eligibility
    def self.executable?(batch)
      batch.ready_preflight_state?
    end
  end
end
