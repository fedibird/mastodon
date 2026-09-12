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
module Moderation
  class FollowGateBacktestService
    DEFAULT_MAX_EVENTS = 2_000

    def initialize(gate_service: Moderation::AdaptiveFollowGateDecisionService.new)
      @gate_service = gate_service
    end

    def call(subject_or_account, max_events: DEFAULT_MAX_EVENTS)
      subject = resolve_subject(subject_or_account)
      return empty_result(subject) if subject.nil?

      follows = follow_events(subject, max_events)
      return empty_result(subject) if follows.empty?

      first_follow_at = follows.first.occurred_at
      friction_counts = Hash.new(0)
      first_friction  = {}
      policy_version  = nil
      params_digest   = nil

      follows.each_with_index do |event, offset|
        decision = @gate_service.call(subject, now: event.occurred_at)
        policy_version ||= decision['policy_version']
        params_digest  ||= decision['params_digest']

        friction = decision['proposed_friction']
        friction_counts[friction] += 1

        next if friction == 'allow' || first_friction.key?(friction)

        first_friction[friction] = {
          'attempt_index'            => offset + 1,
          'occurred_at'              => event.occurred_at.utc.iso8601,
          'minutes_from_first_follow' => ((event.occurred_at - first_follow_at) / 60.0).round(2),
        }
      end

      {
        'subject_id'          => subject.id,
        'generated_at'        => Time.now.utc.iso8601,
        'gate_policy_version' => policy_version,
        'gate_params_digest'  => params_digest,
        'follow_attempts'     => follows.size,
        'first_follow_at'     => first_follow_at.utc.iso8601,
        'last_follow_at'      => follows.last.occurred_at.utc.iso8601,
        'friction_counts'     => friction_counts,
        'first_friction'      => first_friction,
      }
    end

    private

    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def follow_events(subject, max_events)
      ModerationInteractionEvent
        .where(actor_subject_id: subject.id, event_type: :follow)
        .where.not(occurred_at: nil)
        .order(:occurred_at, :id)
        .limit(max_events)
        .to_a
    end

    def empty_result(subject)
      {
        'subject_id'          => subject&.id,
        'generated_at'        => Time.now.utc.iso8601,
        'gate_policy_version' => nil,
        'gate_params_digest'  => nil,
        'follow_attempts'     => 0,
        'first_follow_at'     => nil,
        'last_follow_at'      => nil,
        'friction_counts'     => {},
        'first_friction'      => {},
      }
    end
  end
end
