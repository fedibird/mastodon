# frozen_string_literal: true

# Connects a screening Follow Import batch to Action Review.
#
# Enforcement signal is always `none`: `off` and the threshold modes
# (low/medium/high) release to ready, and `always` holds the batch.
# The shadow classifier may record a calibration observation after this
# decision returns. That observation is not an enforcement signal, is
# not stored on the Action Review request, and is not read here.
# Approval is an operation approval, not an account verdict.
#
# screening is evaluated once under the batch row lock. ready,
# review_required, and stopped are not re-evaluated. The generic
# PreflightReleaseService still performs screening -> ready and still
# refuses to release a held batch. Shadow enqueue happens after the
# lock so classifier latency and failure cannot change the decision.
module FollowImport
  class ActionReviewPreflightService
    def call(batch)
      result = batch.with_lock do
        if batch.screening_preflight_state?
          evaluate_screening!(batch)
        else
          FollowImport::PreflightReleaseService.new.call(batch)
        end
      end
      enqueue_shadow_observation(batch)
      result
    end

    private

    def evaluate_screening!(batch)
      from = batch.preflight_state
      decision = ActionReview::PolicyDecisionService.new.call(
        operation_type: 'follow_import',
        signal_level: 'none',
        evaluation_status: 'ok'
      )

      if decision.requires_review?
        hold!(batch, decision)
        result(batch, from: from, to: batch.preflight_state, released: false, transitioned: true)
      else
        FollowImport::PreflightReleaseService.new.call(batch)
      end
    end

    def hold!(batch, decision)
      ActionReview::RequestService.new.call(
        operation_type: 'follow_import',
        actor_account: batch.for_account,
        resource: batch,
        decision: decision,
        evaluator_version: nil,
        evidence: evidence_for(batch)
      )
      batch.update!(preflight_state: :review_required)
    end

    def evidence_for(batch)
      {
        'schema_version' => 1,
        'batch_id' => batch.id,
        'imported_at' => batch.imported_at&.utc&.iso8601,
        'mode' => batch.mode,
        'target_count' => batch.target_count,
        'resolved_target_count' => batch.resolved_target_count,
        'unresolved_target_count' => batch.unresolved_target_count,
        'account_age_seconds' => batch.account_age_seconds,
        'migration_evidence' => batch.migration_evidence,
        'dispatch_owner' => batch.dispatch_owner,
      }
    end

    def result(batch, from:, to:, released:, transitioned:)
      FollowImport::PreflightReleaseService::Result.new(
        batch_id: batch.id,
        from: from,
        to: to,
        released: released,
        transitioned: transitioned
      )
    end

    # Best-effort. Redis and inline-worker failures are logged by class
    # only and cannot hold, release, or fail the import.
    def enqueue_shadow_observation(batch)
      return unless batch.operational_dispatch_cohort?

      FollowImport::ReviewSignalShadowWorker.perform_async(batch.id)
    rescue StandardError => e
      Rails.logger.warn("[FollowImport::ActionReviewPreflightService] shadow enqueue failed for batch #{batch.id}: #{e.class}")
    end
  end
end
