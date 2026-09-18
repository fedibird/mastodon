# frozen_string_literal: true

class Api::V1::Instances::TranslationLanguagesController < Api::BaseController
  skip_before_action :require_authenticated_user!, unless: :whitelist_mode?

  def show
    expires_in 1.day, public: true
    render json: {}
  end
end
