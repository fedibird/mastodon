# frozen_string_literal: true

class Settings::ExternalServices::RSSController < Settings::BaseController
  include ChallengableConcern

  before_action :require_page_challenge!

  def show
    @page = ExternalServices::RSS.page_for(current_user, page: params[:page])
  end

  private

  def require_page_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    @challenge = Form::Challenge.new(return_to: settings_external_services_rss_path)
    render_challenge
  end
end
