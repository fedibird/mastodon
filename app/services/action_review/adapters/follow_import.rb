# frozen_string_literal: true

# Follow Import approve/stop adapter.
#
# Approve is permission to run this import, not a trust verdict on the
# account. Reject stops only this import. Lock the batch, then the
# review request, so concurrent moderators serialize on one order.
# Resume enqueue is at-least-once after commit; a lost enqueue is
# recovered by Scheduler::FollowImportActionReviewResumeScheduler.
module ActionReview
  module Adapters
    class FollowImport
      DECISIONS = %w(approve reject).freeze

      def self.actionable?(request)
        return false unless request.respond_to?(:pending_state?) && request.pending_state?

        resource = request.resource
        resource.is_a?(::FollowImportBatch) && request.resource_type == 'FollowImportBatch' && resource.review_required_preflight_state?
      rescue StandardError
        false
      end

      def call(request:, decision:, reviewer_account:, decision_note: nil)
        verb = decision.to_s
        raise ActionReview::DecisionError, 'unsupported decision' unless DECISIONS.include?(verb)

        batch = nil
        outcome = nil
        ApplicationRecord.transaction do
          batch = locked_batch!(request)
          request.lock!
          request.reload
          batch.reload
          outcome = apply!(request, batch, verb, reviewer_account, decision_note)
        end

        after_commit(batch, request, outcome)
        outcome
      end

      private

      def locked_batch!(request)
        resource = request.resource
        unless resource.is_a?(::FollowImportBatch) && request.resource_type == 'FollowImportBatch' && request.resource_id == resource.id
          raise ActionReview::DecisionError, 'follow import review resource is missing or mismatched'
        end

        ::FollowImportBatch.lock.find(resource.id)
      rescue ActiveRecord::RecordNotFound
        raise ActionReview::DecisionError, 'follow import review resource is missing or mismatched'
      end

      def apply!(request, batch, verb, reviewer_account, decision_note)
        return idempotent!(request, batch, verb) unless request.pending_state?
        raise ActionReview::DecisionError, 'batch is not waiting for review' unless batch.review_required_preflight_state?

        note = normalize_note(decision_note)
        now = Time.now.utc
        request.update!(
          state: verb == 'approve' ? :approved : :rejected,
          reviewer_account: reviewer_account,
          reviewed_at: now,
          decision_note: note
        )

        if verb == 'approve'
          batch.mark_review_resume_required!(now)
          :approved
        else
          batch.update!(preflight_state: :stopped)
          :rejected
        end
      end

      def idempotent!(request, batch, verb)
        if verb == 'approve' && request.approved_state? && batch.ready_preflight_state?
          return :already_approved
        end
        if verb == 'reject' && request.rejected_state? && batch.stopped_preflight_state?
          return :already_rejected
        end

        raise ActionReview::DecisionError, 'action review request is already decided'
      end

      def normalize_note(decision_note)
        text = decision_note.to_s.strip
        text.presence
      end

      def after_commit(batch, request, outcome)
        case outcome
        when :approved, :already_approved
          enqueue_resume(request)
        when :rejected
          discard_import(batch)
        end
      end

      def enqueue_resume(request)
        ::FollowImport::ActionReviewResumeWorker.perform_async(request.id)
      rescue StandardError => e
        Rails.logger.warn("[ActionReview::Adapters::FollowImport] resume enqueue failed for request #{request.id}: #{e.class}: #{e.message}")
      end

      def discard_import(batch)
        Import.find_by(id: batch.import_id)&.destroy
      rescue StandardError => e
        Rails.logger.warn("[ActionReview::Adapters::FollowImport] csv cleanup failed for batch #{batch.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
