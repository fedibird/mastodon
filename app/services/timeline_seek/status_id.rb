# frozen_string_literal: true

module TimelineSeek
  # Decimal status ids only. Floats, signs, and strings that do not fit in a
  # signed bigint are rejected so they cannot be echoed or queried.
  module StatusId
    MAX_BIGINT = 9_223_372_036_854_775_807

    module_function

    def parse(value)
      return nil if value.is_a?(Numeric) && !value.is_a?(Integer)

      text = value.to_s
      return nil unless text.match?(/\A[0-9]+\z/)
      return nil if text.length > 19
      return nil if text.length == 19 && text > MAX_BIGINT.to_s

      Integer(text, 10)
    end
  end
end
