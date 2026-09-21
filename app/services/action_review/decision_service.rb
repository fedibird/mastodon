# frozen_string_literal: true

# Dispatches a moderator decision to the operation adapter.
# Generic code does not know how Follow Import releases or stops.
module ActionReview
  class DecisionService
    def call(request:, decision:, reviewer_account:, decision_note: nil)
      ActionReview::OperationRegistry.fetch!(request.operation_type)
      ActionReview::AdapterRegistry.fetch!(request.operation_type).new.call(
        request: request,
        decision: decision,
        reviewer_account: reviewer_account,
        decision_note: decision_note
      )
    end
  end
end
