# frozen_string_literal: true

module UserCredentialVault
  # Machine-readable names only. The message never echoes the rejected value.
  module Identifiers
    module_function

    def check!(name, value)
      string = value.is_a?(String) ? value : nil
      raise ArgumentError, "#{name} is not a valid identifier" unless string&.match?(UserExternalCredential::IDENTIFIER_FORMAT)

      string
    end
  end
end
