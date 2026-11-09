# frozen_string_literal: true

class Settings::CustomEmojis::MutesController < Settings::BaseController
  before_action :require_not_suspended!

  def show; end
end
