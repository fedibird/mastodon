# frozen_string_literal: true

module GroupCreationRequests
  # Rejects one pending request. A blank reason is refused. No group
  # Account, role, policy, or follow is created. The requester's cancel
  # path is a different lock on the same row, so only one terminal state
  # commits.
  class RejectService
    def self.call(request:, reviewer_account:, decision_note:)
      new(request, reviewer_account, decision_note).call
    end

    def initialize(request, reviewer_account, decision_note)
      @request = request
      @reviewer_account = reviewer_account
      @decision_note = decision_note
    end

    def call
      note = @decision_note.to_s.strip
      raise DecisionError, :decision_note_blank if note.blank?
      raise DecisionError, :feature_disabled unless Feature.enabled?
      raise DecisionError, :not_authorized unless GroupManagement.server_administrator?(@reviewer_account)

      GroupCreationRequest.transaction do
        @request.lock!
        raise DecisionError, :not_pending unless @request.pending?
        raise DecisionError, :feature_disabled unless Feature.enabled?
        raise DecisionError, :not_authorized unless GroupManagement.server_administrator?(@reviewer_account)

        @request.record_rejection!(reviewer_account: @reviewer_account, decision_note: note)
        GroupCreationDecision.record!(@request)
      end
      DecisionResult.new(request: @request, code: :rejected)
    rescue DecisionError => e
      DecisionResult.new(request: reload_request, code: e.code)
    rescue ActiveRecord::RecordNotUnique
      DecisionResult.new(request: reload_request, code: :conflict)
    rescue ActiveRecord::RecordInvalid => e
      DecisionResult.new(request: reload_request, code: invalid_code(e))
    end

    private

    def reload_request
      GroupCreationRequest.find(@request.id)
    end

    def invalid_code(error)
      record = error.record
      return :not_authorized if record.is_a?(GroupCreationRequest) && record.errors.of_kind?(:reviewer_account, :invalid)
      return :not_pending if record.is_a?(GroupCreationRequest) && record.errors.of_kind?(:state, :invalid)
      return :decision_note_blank if record.is_a?(GroupCreationRequest) && record.errors.of_kind?(:decision_note, :blank)

      :conflict
    end
  end
end
