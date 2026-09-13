# frozen_string_literal: true

# The single boundary for changing a FollowImportTarget's execution state.
# Workers and ActivityPub handlers must go through here rather than updating the
# state directly, so transitions stay idempotent, retry-safe, concurrency-safe,
# and — crucially — a terminal result is never overwritten by a late or duplicate
# callback (Accept/Reject and delivery bookkeeping can race).
#
# The DB row is the source of truth; each transition takes a row lock and either
# applies an allowed forward move (setting its timestamps/attributes) or is a
# silent no-op (idempotent self-transition, or a refused rollback/terminal
# overwrite). Nothing here performs enforcement or touches the moderation ledger.
#
# INVARIANT (enforced by callers, relied on here): a target's follow_request_uri
# and its state (>= queued) MUST be persisted BEFORE the ActivityPub Follow is
# enqueued for delivery. Otherwise an inbound Accept/Reject could arrive with no
# target to correlate to. Because of this, an Accept/Reject can legitimately race
# ahead of the delivery-success bookkeeping (mark_awaiting_response): it may be
# observed while the target is still queued or awaiting_delivery. accepted/rejected
# are therefore reachable from those states too, and — being terminal — a later
# delivery callback (mark_awaiting_response) or sweep (mark_completed_no_response)
# is refused, so it can never be wrongly downgraded to completed_no_response.
module FollowImport
  class TargetTransitionService
    # Allowed forward transitions. Terminal states are intentionally absent as
    # keys, so any move out of a terminal state is refused. Same-state moves are
    # treated as idempotent no-ops before this table is consulted. accepted/rejected
    # are permitted from queued/awaiting_delivery as well as awaiting_response so an
    # Accept/Reject that races ahead of delivery bookkeeping is not lost.
    ALLOWED_TRANSITIONS = {
      'pending'           => %w(queued awaiting_delivery awaiting_response delivery_failed).freeze,
      'queued'            => %w(awaiting_delivery awaiting_response accepted rejected delivery_failed).freeze,
      'awaiting_delivery' => %w(awaiting_response accepted rejected delivery_failed).freeze,
      'awaiting_response' => %w(accepted rejected completed_no_response delivery_failed).freeze,
    }.freeze

    def mark_queued(target, follow_request_uri: nil, at: Time.now.utc)
      # Persisting the correlation URI together with the queued state satisfies
      # the invariant that it exists before the Follow is enqueued for delivery.
      transition(target, 'queued',
                 attributes: { 'follow_request_uri' => follow_request_uri }.compact,
                 timestamps: { 'queued_at' => at })
    end

    def mark_awaiting_delivery(target)
      transition(target, 'awaiting_delivery')
    end

    # Records that the ActivityPub Follow was delivered and we are now waiting for
    # an Accept/Reject until response_deadline_at.
    def mark_awaiting_response(target, follow_request_uri:, response_deadline_at:, delivered_at: Time.now.utc)
      transition(target, 'awaiting_response',
                 attributes: { 'follow_request_uri' => follow_request_uri }.compact,
                 timestamps: { 'delivered_at' => delivered_at, 'response_deadline_at' => response_deadline_at })
    end

    def mark_accepted(target, at: Time.now.utc)
      transition(target, 'accepted', timestamps: { 'completed_at' => at })
    end

    def mark_rejected(target, at: Time.now.utc)
      transition(target, 'rejected', timestamps: { 'completed_at' => at })
    end

    # Our wait for a response finished — this only means import processing is done
    # for this target, NOT that it was rejected.
    def mark_completed_no_response(target, at: Time.now.utc)
      transition(target, 'completed_no_response', timestamps: { 'completed_at' => at })
    end

    def mark_delivery_failed(target, failure_code: nil, at: Time.now.utc)
      transition(target, 'delivery_failed',
                 attributes: { 'failure_code' => failure_code }.compact,
                 timestamps: { 'completed_at' => at })
    end

    # Narrowly-scoped recovery for the claim/enqueue window ONLY. The batch
    # executor persists pending -> queued to claim a target BEFORE enqueuing its
    # work; if that enqueue then fails, the claim must be released so a retry can
    # reselect (only `pending` targets are claimable). This is the sole backwards
    # transition and is deliberately not part of ALLOWED_TRANSITIONS: it rolls
    # queued -> pending and refuses if the target has already advanced past queued
    # (someone is handling it) or is not queued.
    def release_queued_claim(target)
      target.with_lock do
        return target unless target.state == 'queued'

        target.update!(state: 'pending', queued_at: nil)
      end

      target
    end

    # Delivery-attempt bookkeeping is not a state transition; each (re)attempt
    # bumps the counter under a row lock.
    def record_delivery_attempt(target)
      target.with_lock { target.update!(delivery_attempts: target.delivery_attempts + 1) }
      target
    end

    # Applies +to+ if allowed from the current state; otherwise a silent no-op.
    # Returns the target. A refused transition (rollback or terminal overwrite) or
    # a repeated same-state transition never changes the row, so late/duplicate
    # callbacks cannot corrupt the source-of-truth state.
    def transition(target, to, attributes: {}, timestamps: {})
      to = to.to_s

      target.with_lock do
        from = target.state
        return target if from == to
        return target unless Array(ALLOWED_TRANSITIONS[from]).include?(to)

        target.update!({ 'state' => to }.merge(attributes).merge(timestamps))
      end

      target
    end
  end
end
