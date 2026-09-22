# frozen_string_literal: true

# Approve or stop one account-migration review.
#
# Approval records the decision and leaves MoveService to the execution
# worker after commit. Rejection leaves the source account where it is.
# Neither decision creates a ModerationAction. A cancelled request is
# terminal and is not actionable.
module ActionReview
  module Adapters
    class AccountMigration
      DECISIONS = %w(approve reject).freeze

      def self.actionable?(request)
        return false unless request.respond_to?(:pending_state?) && request.pending_state?
        return false unless request.operation_type == 'account_migration'
        return false unless request.resource_type == 'AccountMigration'

        migration = request.resource
        return false unless migration.is_a?(::AccountMigration) && migration.id == request.resource_id
        return false unless recognized_evidence?(request.evidence)
        return false unless consistent?(request, migration)

        true
      rescue StandardError
        false
      end

      def self.recognized_evidence?(evidence)
        return false unless evidence.is_a?(Hash)
        return false unless evidence['schema_version'] == ::AccountMigration::CreateService::EVIDENCE_SCHEMA_VERSION
        return false unless evidence['target_acct'].is_a?(String) && evidence['target_acct'].present?
        return false unless evidence['followers_count_at_request'].is_a?(Integer) && evidence['followers_count_at_request'] >= 0
        return false unless evidence['target_account_local'] == true || evidence['target_account_local'] == false
        return false unless evidence['metrics'].is_a?(Hash)

        evidence['metrics']['as_of'].is_a?(String)
      end

      # Cached account columns only. No webfinger or other network read.
      def self.consistent?(request, migration)
        source = migration.account
        target = migration.target_account
        return false if source.nil? || target.nil?
        return false unless actor_matches?(request, migration)
        return false unless source.local?
        return false if source.suspended?
        return false if source.id == target.id
        return false if moved_elsewhere?(source, target)

        target_references_source?(source, target)
      end

      def self.actor_matches?(request, migration)
        request.actor_account_id.present? && request.actor_account_id == migration.account_id
      end

      def self.moved_elsewhere?(source, target)
        source.moved_to_account_id.present? && source.moved_to_account_id != target.id
      end

      def self.target_references_source?(source, target)
        uri = ActivityPub::TagManager.instance.uri_for(source)
        target.also_known_as.include?(uri)
      end

      def call(request:, decision:, reviewer_account:, decision_note: nil)
        verb = decision.to_s
        raise ActionReview::DecisionError, 'unsupported decision' unless DECISIONS.include?(verb)

        outcome = ApplicationRecord.transaction do
          migration = locked_migration!(request)
          request.lock!
          request.reload
          migration.reload
          apply!(request, migration, verb, reviewer_account, decision_note)
        end

        enqueue_execution(request) if outcome == :approved
        outcome
      end

      private

      def locked_migration!(request)
        resource = request.resource
        unless resource.is_a?(::AccountMigration) && request.resource_type == 'AccountMigration' && request.resource_id == resource.id && request.operation_type == 'account_migration'
          raise ActionReview::DecisionError, 'account migration review resource is missing or mismatched'
        end

        ::AccountMigration.lock.find(resource.id)
      rescue ActiveRecord::RecordNotFound
        raise ActionReview::DecisionError, 'account migration review resource is missing or mismatched'
      end

      def apply!(request, migration, verb, reviewer_account, decision_note)
        return idempotent!(request, verb) unless request.pending_state?

        ensure_consistent!(request, migration)
        request.update!(
          state: verb == 'approve' ? :approved : :rejected,
          reviewer_account: reviewer_account,
          reviewed_at: Time.now.utc,
          decision_note: decision_note.to_s.strip.presence
        )
        verb == 'approve' ? :approved : :rejected
      end

      def ensure_consistent!(request, migration)
        raise ActionReview::DecisionError, 'account migration review evidence is not recognized' unless self.class.recognized_evidence?(request.evidence)
        raise ActionReview::DecisionError, 'account migration review is not consistent' unless self.class.consistent?(request, migration)
      end

      def idempotent!(request, verb)
        return :already_approved if verb == 'approve' && request.approved_state?
        return :already_rejected if verb == 'reject' && request.rejected_state?

        raise ActionReview::DecisionError, 'action review request is already decided'
      end

      # After the decision transaction commits. A lost enqueue leaves the
      # approved row in place so the recovery scheduler can try again.
      def enqueue_execution(request)
        ::AccountMigration::ActionReviewExecutionWorker.perform_async(request.id)
      rescue StandardError
        nil
      end
    end
  end
end
