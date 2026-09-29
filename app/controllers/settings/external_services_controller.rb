# frozen_string_literal: true

class Settings::ExternalServicesController < Settings::BaseController
  include ChallengableConcern

  before_action :require_page_challenge!

  def index
    @connections = ExternalServices::Registry.connections_for(current_user)
  end

  def new
    @providers = ExternalServices::Registry.catalog_for(current_user)
  end

  private

  # Challenge the clean settings path. request.url is not used, so a query
  # string cannot be copied into the challenge form.
  def require_page_challenge!
    return if skip_challenge?

    if challenge_passed_recently?
      session[:challenge_passed_at] = Time.now.utc
      return
    end

    @challenge = Form::Challenge.new(return_to: challenge_return_path)
    render_challenge
  end

  def challenge_return_path
    if action_name == 'new'
      new_settings_external_service_path
    else
      settings_external_services_path
    end
  end
end
