# frozen_string_literal: true

class UserPreferences::InvalidInput < ArgumentError
  attr_reader :errors

  def initialize(errors)
    @errors = errors.map { |error| error.dup.freeze }.freeze
    super('invalid preference input')
  end
end
