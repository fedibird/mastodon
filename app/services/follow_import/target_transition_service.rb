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
module FollowImport
  class TargetTransitionService
    # Allowed forward transitions. Terminal states are intentionally absent as
    # keys, so any move out of a terminal state is refused. Same-state moves are
    # treated as idempotent no-ops before this table is consulted.
    ALLOWED_TRANSITIONS = {
      'pending'           => %w(queued awaiting_delivery awaiting_response delivery_failed).freeze,
      'queued'            => %w(awaiting_delivery awaiting_response delivery_failed).freeze,
      'awaiting_delivery' => %w(awaiting_response delivery_failed).freeze,
      'awaiting_response' => %w(accepted rejected completed_no_response delivery_failed).freeze,
    }.freeze

    def mark_queued(target, at: Time.now.utc)
      transition(target, 'queued', timestamps: { 'queued_at' => at })
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
