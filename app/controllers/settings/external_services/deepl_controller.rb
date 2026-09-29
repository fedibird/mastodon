# frozen_string_literal: true

class Settings::ExternalServices::DeepLController < Settings::BaseController
  include ChallengableConcern

  before_action :require_page_challenge!

  def show
    @page = ExternalServices::DeepL.page_for(current_user)
  end

  private

  # Challenge the clean DeepL path. request.url is not used, so a query
  # string cannot be copied into the challenge form.
  def require_page_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    @challenge = Form::Challenge.new(return_to: settings_external_services_deepl_path)
    render_challenge
  end
end
