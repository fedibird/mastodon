# frozen_string_literal: true

class Settings::ExternalCredentialsController < Settings::BaseController
  include ChallengableConcern

  before_action :require_page_challenge!

  def show
    @credentials = DeepLCredentialSettings.scope_for(current_user).order(:id).to_a
    @vault_available = UserCredentialVault.available?
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

    @challenge = Form::Challenge.new(return_to: settings_external_credentials_path)
    render_challenge
  end
end
