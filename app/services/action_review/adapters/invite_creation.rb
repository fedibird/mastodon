# frozen_string_literal: true

# Approve or stop one invite-creation review.
#
# The pending resource is an expired Invite shell. Approval restores the
# requested lifetime from the approval instant. Rejection leaves the
# shell expired. Neither decision creates a ModerationAction or changes
# max_uses, autofollow, comment, or account state. A later expire or
# exhausted max_uses is ordinary Invite behavior; repeating approve does
# not revive it.
module ActionReview
  module Adapters
    class InviteCreation
      DECISIONS = %w(approve reject).freeze

      def self.actionable?(request)
        return false unless request.respond_to?(:pending_state?) && request.pending_state?
        return false unless request.operation_type == 'invite_creation'
        return false unless request.resource_type == 'Invite'

        invite = request.resource
        return false unless invite.is_a?(::Invite) && invite.id == request.resource_id
        return false unless pending_shell?(invite)
        return false unless recognized_evidence?(request.evidence)
        return false unless actor_matches?(request, invite)

        true
      rescue StandardError
        false
      end

      def self.recognized_evidence?(evidence)
        return false unless evidence.is_a?(Hash)
        return false unless evidence['schema_version'] == ::InviteCreation::CreateService::EVIDENCE_SCHEMA_VERSION
        return false unless evidence.key?('requested_expires_in_seconds')

        seconds = evidence['requested_expires_in_seconds']
        seconds.nil? || (seconds.is_a?(Integer) && seconds >= 0)
      end

      def self.pending_shell?(invite)
        invite.expired? && invite.uses.to_i.zero?
      end

      def self.actor_matches?(request, invite)
        account_id = request.actor_account_id
        account_id.present? && invite.user&.account_id == account_id
      end

      def call(request:, decision:, reviewer_account:, decision_note: nil)
        verb = decision.to_s
        raise ActionReview::DecisionError, 'unsupported decision' unless DECISIONS.include?(verb)

        ApplicationRecord.transaction do
          invite = locked_invite!(request)
          request.lock!
          request.reload
          invite.reload
          apply!(request, invite, verb, reviewer_account, decision_note)
        end
      end

      private

      def locked_invite!(request)
        resource = request.resource
        unless resource.is_a?(::Invite) && request.resource_type == 'Invite' && request.resource_id == resource.id && request.operation_type == 'invite_creation'
          raise ActionReview::DecisionError, 'invite review resource is missing or mismatched'
        end

        ::Invite.lock.find(resource.id)
      rescue ActiveRecord::RecordNotFound
        raise ActionReview::DecisionError, 'invite review resource is missing or mismatched'
      end

      def apply!(request, invite, verb, reviewer_account, decision_note)
        return idempotent!(request, verb) unless request.pending_state?

        ensure_pending_shell!(request, invite)
        now = Time.now.utc
        request.update!(
          state: verb == 'approve' ? :approved : :rejected,
          reviewer_account: reviewer_account,
          reviewed_at: now,
          decision_note: normalize_note(decision_note)
        )
        invite.update!(expires_at: restored_expires_at(request, now)) if verb == 'approve'
        verb == 'approve' ? :approved : :rejected
      end

      def ensure_pending_shell!(request, invite)
        raise ActionReview::DecisionError, 'invite review evidence is not recognized' unless self.class.recognized_evidence?(request.evidence)
        raise ActionReview::DecisionError, 'invite review actor does not match the invite' unless self.class.actor_matches?(request, invite)
        raise ActionReview::DecisionError, 'invite is not an unusable pending shell' unless self.class.pending_shell?(invite)
      end

      def restored_expires_at(request, now)
        seconds = request.evidence['requested_expires_in_seconds']
        return nil if seconds.nil?

        now + seconds.seconds
      end

      # Terminal state is the idempotency key. valid_for_use? is not:
      # an approved code may later expire or run out of uses.
      def idempotent!(request, verb)
        return :already_approved if verb == 'approve' && request.approved_state?
        return :already_rejected if verb == 'reject' && request.rejected_state?

        raise ActionReview::DecisionError, 'action review request is already decided'
      end

      def normalize_note(decision_note)
        decision_note.to_s.strip.presence
      end
    end
  end
end
