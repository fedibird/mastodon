# frozen_string_literal: true

module GroupRegistrationInvites
  # Parses invite-policy form values. Blank and non-integers become nil so
  # the model, or the site-default writer, can reject them. Negatives and
  # fractions are rejected here. The upper bound is the PostgreSQL integer
  # column.
  module Attributes
    INTEGER_MAX = 2_147_483_647

    module_function

    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def strict_integer(value)
      text = value.to_s.strip
      return if text.blank?
      return unless text.match?(/\A[0-9]+\z/)

      number = Integer(text, 10)
      return if number > INTEGER_MAX

      number
    end
  end
end
