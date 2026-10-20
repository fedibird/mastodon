# frozen_string_literal: true

class Settings::ExternalServices::BlueskyController < Settings::BaseController
  include ChallengableConcern

  before_action :require_page_challenge!

  def show
    @page = ExternalServices::Bluesky.page_for(current_user)
  end

  private

  def require_page_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    @challenge = Form::Challenge.new(return_to: settings_external_services_bluesky_path)
    render_challenge
  end
end
