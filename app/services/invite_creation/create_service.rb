# frozen_string_literal: true

# Issues an Invite, or an unusable expired shell plus one pending Action
# Review request when invite_creation policy is always.
#
# signal_level stays none. There is no invite classifier. The shell and
# the review row commit together. A failed review write rolls the shell
# back, so a usable code is never left without a decision, and an
# unusable shell is never left without its review request.
module InviteCreation
  class CreateService
    EVIDENCE_SCHEMA_VERSION = 1

    Result = Struct.new(:invite, :request, :status, keyword_init: true) do
      def issued?
        status == :issued
      end

      def pending_review?
        status == :pending_review
      end

      def invalid?
        status == :invalid
      end
    end

    def call(user:, attributes:)
      invite = Invite.new(attributes)
      invite.user = user
      seconds = requested_expires_in_seconds(invite)
      decision = ActionReview::PolicyDecisionService.new.call(
        operation_type: 'invite_creation',
        signal_level: 'none',
        evaluation_status: 'ok'
      )

      if decision.requires_review?
        hold(invite, user, decision, seconds)
      else
        issue(invite)
      end
    end

    private

    def issue(invite)
      if invite.save
        Result.new(invite: invite, request: nil, status: :issued)
      else
        Result.new(invite: invite, request: nil, status: :invalid)
      end
    end

    def hold(invite, user, decision, seconds)
      invite.expires_at = Time.now.utc - 1.second
      request = nil
      ApplicationRecord.transaction do
        invite.save!
        request = ActionReview::RequestService.new.call(
          operation_type: 'invite_creation',
          actor_account: user.account,
          resource: invite,
          decision: decision,
          evidence: evidence_for(invite, seconds)
        ).request
        raise ActiveRecord::Rollback if request.nil?
      end
      raise ActiveRecord::RecordNotSaved, 'invite review was not recorded' if request.nil?

      Result.new(invite: invite, request: request, status: :pending_review)
    rescue ActiveRecord::RecordInvalid
      Result.new(invite: invite, request: nil, status: :invalid)
    end

    # Expireable stores the requested interval on the instance. Blank
    # means no expiration. The pending shell overwrites expires_at, so
    # the duration has to be captured before that overwrite.
    def requested_expires_in_seconds(invite)
      return nil unless invite.instance_variable_defined?(:@expires_in)

      raw = invite.instance_variable_get(:@expires_in)
      return nil if raw.blank?

      raw.to_i
    end

    def evidence_for(invite, seconds)
      {
        'schema_version' => EVIDENCE_SCHEMA_VERSION,
        'requested_max_uses' => invite.max_uses,
        'requested_expires_in_seconds' => seconds,
        'autofollow' => invite.autofollow?,
        'comment_present' => invite.comment.present?,
      }
    end
  end
end
