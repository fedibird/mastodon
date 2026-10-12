# frozen_string_literal: true

class Api::V1::Fedibird::PreferencesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:preferences' }, only: :show
  before_action -> { doorkeeper_authorize! :'write:preferences' }, only: :update
  before_action :require_user!
  after_action :set_private_no_store

  def show
    render json: UserPreferences::PreferenceDocument.new(current_user).as_json
  end

  def update
    updates = UserPreferences::PatchDocument.parse(json_body)
    UserPreferences::Writer.new(current_user).apply(updates: updates)
    render json: UserPreferences::PreferenceDocument.new(current_user).as_json
  rescue UserPreferences::InvalidInput => error
    render json: { error: 'Invalid preferences', errors: public_errors(error) }, status: 422
  rescue UserPreferences::Conflict
    render json: { error: 'Preferences conflict' }, status: 409
  end

  private

  def json_body
    unless request.content_mime_type == Mime[:json]
      raise UserPreferences::InvalidInput, [{ 'key' => nil, 'code' => 'invalid_body' }]
    end

    raw = request.raw_post
    return {} if raw.blank?

    parsed = ActiveSupport::JSON.decode(raw)
    return parsed if parsed.is_a?(Hash)

    raise UserPreferences::InvalidInput, [{ 'key' => nil, 'code' => 'invalid_body' }]
  end

  def public_errors(error)
    error.errors.map do |item|
      key = item['key']
      { 'key' => public_key(key), 'code' => item['code'] }
    end
  end

  def public_key(key)
    return "user.#{key}" if UserPreferences::WriteContract::KEYS.include?(key)

    key
  end

  def set_private_no_store
    response.headers['Cache-Control'] = 'private, no-store'
  end
end
