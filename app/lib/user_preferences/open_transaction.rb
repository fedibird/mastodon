# frozen_string_literal: true

class UserPreferences::OpenTransaction < StandardError
  def initialize
    super('preference writer cannot run inside an open transaction')
  end
end
