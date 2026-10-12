# frozen_string_literal: true

class UserPreferences::Conflict < StandardError
  def initialize
    super('preference write conflicted with another save')
  end
end
