# frozen_string_literal: true

# Read-only summary of what a shadow dispatch tick observed.
#
# PR A must not select targets for execution. This object carries cheap
# backlog/config facts only. Account-first DRR, owner_key, batch
# sub-scheduling, and destination-share planning belong to PR B and must
# not be prototyped here as a temporary batch-first policy.
module FollowImport
  class DispatchPlan
    attr_reader :observed_at, :global_pending_count, :active_batch_count, :execution_config

    def self.observe(observed_at:, global_pending_count:, active_batch_count:, execution_config:)
      new(
        observed_at: observed_at,
        global_pending_count: global_pending_count,
        active_batch_count: active_batch_count,
        execution_config: execution_config
      )
    end

    def initialize(observed_at:, global_pending_count:, active_batch_count:, execution_config:)
      @observed_at = observed_at
      @global_pending_count = global_pending_count
      @active_batch_count = active_batch_count
      @execution_config = execution_config
    end

    # PR A shadow mode never claims. Later claiming PRs must not inherit a
    # hidden non-zero default from this skeleton.
    def claimed_count
      0
    end
  end
end
