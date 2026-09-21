# frozen_string_literal: true

# Neutral screening -> ready release for Follow Import batches.
#
# This is an execution-safety primitive, not a moderation decision.
# It never infers risk, identity, or abuse, and it does not enqueue
# work. ImportService calls it after recording so current imports
# still execute immediately, while leaving a single insertion point
# for a later preflight evaluator.
#
# Next PR: after a batch is durably recorded in screening, a
# preflight evaluator may inspect the known target set and
# transition exactly one way:
#   screening -> ready
#   screening -> review_required
# A moderator workflow can later transition:
#   review_required -> ready
#   review_required -> stopped
# There is no automatic review_required -> ready path. This service
# must never release review_required or stopped.
module FollowImport
  class PreflightReleaseService
    Result = Struct.new(:batch_id, :from, :to, :released, :transitioned, keyword_init: true) do
      def released?
        released
      end
    end

    def call(batch)
      batch.with_lock do
        from = batch.preflight_state

        if batch.ready_preflight_state?
          Result.new(batch_id: batch.id, from: from, to: from, released: true, transitioned: false)
        elsif batch.screening_preflight_state?
          batch.update!(preflight_state: :ready)
          Result.new(batch_id: batch.id, from: from, to: batch.preflight_state, released: true, transitioned: true)
        else
          Result.new(batch_id: batch.id, from: from, to: from, released: false, transitioned: false)
        end
      end
    end
  end
end
