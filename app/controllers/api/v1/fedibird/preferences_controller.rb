# frozen_string_literal: true

class Api::V1::Fedibird::PreferencesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:preferences' }
  before_action :require_user!
  after_action :set_private_no_store

  def show
    render json: UserPreferences::PreferenceDocument.new(current_user).as_json
  end

  private

  def set_private_no_store
    response.headers['Cache-Control'] = 'private, no-store'
  end
end
