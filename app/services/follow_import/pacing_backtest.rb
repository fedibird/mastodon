# frozen_string_literal: true

# Read-only offline backtest of Follow Import pacing profiles against
# exported telemetry CSVs. This is analysis tooling only: it does not
# enable GLOBAL, remote-admission enforcement, or adaptive enforcement,
# and it never writes Follow Import rows, Redis, or the network.
module FollowImport
  class PacingBacktest
    SCHEMA_NAME = 'follow_import_pacing_backtest'
    SCHEMA_VERSION = 1
    SCENARIO_SCHEMA_VERSION = 1
    PERCENTILE_METHOD = 'nearest_rank_ceil'

    CAUSAL_WARNING = 'Observational constraint exposure only. Caps, suppression windows, and adaptive trajectories do not prove prevented failures, created successes, or CPU/DB safety.'
    RIGHT_CENSOR_WARNING = 'Targets with a failed first attempt and no later success in this export are no_later_success_observed_within_window. That is right-censored, not a final failure probability.'
    ALL_ATTEMPT_NOTE = 'all-attempt cap excess is diagnostic transport pressure on actual HTTP requests; scheduler claim caps do not directly pace Sidekiq retries. Pre-request DeliveryWorker executions are not HTTP attempts.'
    NO_REFLOW_NOTE = 'Attempts above a bucket cap are counted in that historical bucket. They are not moved into later buckets.'
    CPU_DB_WARNING = 'Exported pacing telemetry does not include CPU or database saturation, so a global-budget envelope must not be read as resource safety.'
    MODERATION_WARNING = 'Accept/Reject, Follow Gate, blocks, reports, and other moderation signals are excluded from this tool.'
    SYNTHETIC_TICK_NOTE = 'bucket_seconds is the scenario synthetic scheduler tick width. per_tick_cap and global_budget are compared to counts inside that bucket, not to wall-clock minutes or historical scheduler tick boundaries.'

    class Error < StandardError; end

    def self.call(**paths)
      Analyzer.new(paths).run
    end
  end
end
