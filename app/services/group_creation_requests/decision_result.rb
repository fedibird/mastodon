# frozen_string_literal: true

module GroupCreationRequests
  # Typed outcome of an administrator decision. Expected failures stay on
  # this object so a caller can render them without a 500. Unexpected
  # exceptions still propagate after the transaction rolls back.
  class DecisionResult
    attr_reader :request, :group_account, :code

    def initialize(request:, code:, group_account: nil)
      @request = request
      @group_account = group_account
      @code = code.to_sym
    end

    def success?
      %i(approved rejected).include?(code)
    end
  end
end
