# frozen_string_literal: true

module WebUiDomains
  # Strict mode for an additional entrance.
  #
  # The closed gate is the only one production code uses. Tests pass
  # Gate.open_for_test into RequestContext.build. Nothing here reads ENV,
  # request headers, or a production flag.
  class Gate
    def self.closed
      @closed ||= new(false).freeze
    end

    def self.open_for_test
      new(true).freeze
    end

    def initialize(enabled)
      @enabled = enabled
    end

    def enabled?
      @enabled
    end
  end
end
