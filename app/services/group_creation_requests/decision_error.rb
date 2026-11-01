# frozen_string_literal: true

module GroupCreationRequests
  # Expected approval or rejection failure. The code is stable for a later
  # UI. Raising it rolls back the surrounding transaction.
  class DecisionError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code.to_sym
      super(@code.to_s)
    end
  end
end
