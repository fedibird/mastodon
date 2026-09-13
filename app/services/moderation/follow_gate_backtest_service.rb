# frozen_string_literal: true

# Replays a subject's recorded follow attempts in chronological order and, for
# each one, asks the adaptive follow gate what it WOULD have proposed as of that
# attempt's time. It answers the calibration question "at what Nth follow / how
# many minutes in would the gate first have proposed friction?" from real ledger
# history.
#
# Strictly analysis-only:
#
#   * Read-only — reads the ledger via the gate/evaluation services (all
#     read-only) and writes nothing.
#   * No enforcement, no friction applied — it only reports what the shadow gate
#     would have proposed, historically.
#   * No future leakage — each follow is evaluated with now = that follow's
#     occurred_at, so later follows/rejections do not influence earlier attempts.
#   * Offline tool — each replayed attempt runs a full metrics evaluation, so the
#     replay is capped (max_events) and is meant to be run on a chosen
#     subject/cohort, not the whole population inline.
#
# Note: per-target routing (confirm_target, which needs the specific target's
# local/unlocked state) is not modeled here; the backtest measures the
# subject-level, behaviour-driven frictions (rate_limit / delay / moderator_review),
# which is the calibration question of interest.
#
# Calibration early-stop (+stop_after_first+): when you only need the first
# firing point of a specific friction, the replay can stop right after that
# friction is first observed, skipping the remaining full evaluations. This does
# NOT change the evaluation semantics — attempts are still evaluated strictly in
# occurred_at order, one at a time, with now = each attempt's occurred_at (no
# sampling, no binary search, no future leakage). It only avoids unnecessary work
# after the requested answer is found; worst case (friction never reached) costs
# the same as a full replay. Every field up to the stopping attempt is identical
# to a full replay's.
module Moderation
  class FollowGateBacktestService
    DEFAULT_MAX_EVENTS = 2_000

    # Frictions whose first firing point can be requested for early stop. Matches
    # the backtest-measurable tiers (confirm_target is not modeled here).
    STOPPABLE_FRICTIONS = %w(rate_limit delay moderator_review).freeze

    def initialize(gate_service: Moderation::AdaptiveFollowGateDecisionService.new)
      @gate_service = gate_service
    end

    def call(subject_or_account, max_events: DEFAULT_MAX_EVENTS, stop_after_first: nil)
      validate_stop_after_first!(stop_after_first)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      subject = resolve_subject(subject_or_account)
      return empty_result(subject, max_events, stop_after_first, started) if subject.nil?

      total_follows = follow_events_count(subject)
      follows       = follow_events(subject, max_events)
      return empty_result(subject, max_events, stop_after_first, started) if follows.empty?

      locality_by_subject_id = target_locality_map(follows)

      first_follow_at       = follows.first.occurred_at
      friction_counts       = Hash.new(0)
      first_friction        = {}
      policy_version        = nil
      params_digest         = nil
      evaluations_performed = 0
      last_evaluated_at     = nil
      early_stopped         = false

      follows.each_with_index do |event, offset|
        # Reconstruct the target's locality so the gate's locality-based routing
        # (local vs remote/unknown) matches what it would have done at attempt
        # time. target_locked is not historically recoverable, so confirm_target
        # remains out of scope.
        context  = { 'target_locality' => locality_by_subject_id[event.target_subject_id] }
        decision = @gate_service.call(subject, context: context, now: event.occurred_at)
        evaluations_performed += 1
        last_evaluated_at      = event.occurred_at
        policy_version ||= decision['policy_version']
        params_digest  ||= decision['params_digest']

        friction = decision['proposed_friction']
        friction_counts[friction] += 1

        unless friction == 'allow' || first_friction.key?(friction)
          first_friction[friction] = {
            'attempt_index'            => offset + 1,
            'occurred_at'              => event.occurred_at.utc.iso8601,
            'minutes_from_first_follow' => ((event.occurred_at - first_follow_at) / 60.0).round(2),
          }
        end

        # Early stop only once the REQUESTED friction is first observed at this
        # attempt (this attempt is already fully counted above). We never infer
        # an unobserved friction from a stronger one that fired.
        if stop_after_first && friction == stop_after_first
          early_stopped = true
          break
        end
      end

      # truncated means the max_events cap cut the observation short. An early stop
      # is NOT truncation: the requested friction was found, so the answer is
      # definitive (do not right-censor it) even if the full history exceeds the cap.
      truncated = !early_stopped && (total_follows > evaluations_performed)

      {
        'subject_id'             => subject.id,
        'generated_at'           => Time.now.utc.iso8601,
        'gate_policy_version'    => policy_version,
        'gate_params_digest'     => params_digest,
        # Only the analyzed window is summarized below (up to the early-stop
        # attempt when early_stopped, otherwise the fetched/possibly-truncated
        # window); friction_counts count only that evaluated range.
        'total_follow_events'    => total_follows,
        'analyzed_follow_events' => evaluations_performed,
        'max_events'             => max_events,
        'truncated'              => truncated,
        'follow_attempts'        => evaluations_performed,
        'first_follow_at'        => first_follow_at.utc.iso8601,
        'last_follow_at'         => last_evaluated_at.utc.iso8601,
        'friction_counts'        => friction_counts,
        'first_friction'         => first_friction,
        'stop_after_first'       => stop_after_first,
        'early_stopped'          => early_stopped,
        'stop_reason'            => early_stopped ? 'requested_first_friction_reached' : nil,
        'evaluations_performed'  => evaluations_performed,
        'elapsed_seconds'        => elapsed_since(started),
      }
    end

    private

    def validate_stop_after_first!(value)
      return if value.nil? || STOPPABLE_FRICTIONS.include?(value)

      raise ArgumentError, "stop_after_first must be nil or one of #{STOPPABLE_FRICTIONS.join(', ')} (got #{value.inspect})"
    end

    def elapsed_since(started)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(6)
    end

    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def follow_events_scope(subject)
      ModerationInteractionEvent
        .where(actor_subject_id: subject.id, event_type: :follow)
        .where.not(occurred_at: nil)
    end

    def follow_events_count(subject)
      follow_events_scope(subject).count
    end

    def follow_events(subject, max_events)
      follow_events_scope(subject).order(:occurred_at, :id).limit(max_events).to_a
    end

    # Reconstruct target locality from each target's ModerationSubject origin.
    # A missing target subject (nullified after deletion) yields nil, which the
    # gate treats as non-local/unknown.
    def target_locality_map(follows)
      ids = follows.map(&:target_subject_id).compact.uniq
      return {} if ids.empty?

      ModerationSubject.where(id: ids).each_with_object({}) do |subject, map|
        map[subject.id] = subject.origin
      end
    end

    def empty_result(subject, max_events, stop_after_first, started)
      {
        'subject_id'             => subject&.id,
        'generated_at'           => Time.now.utc.iso8601,
        'gate_policy_version'    => nil,
        'gate_params_digest'     => nil,
        'total_follow_events'    => 0,
        'analyzed_follow_events' => 0,
        'max_events'             => max_events,
        'truncated'              => false,
        'follow_attempts'        => 0,
        'first_follow_at'        => nil,
        'last_follow_at'         => nil,
        'friction_counts'        => {},
        'first_friction'         => {},
        'stop_after_first'       => stop_after_first,
        'early_stopped'          => false,
        'stop_reason'            => nil,
        'evaluations_performed'  => 0,
        'elapsed_seconds'        => elapsed_since(started),
      }
    end
  end
end
