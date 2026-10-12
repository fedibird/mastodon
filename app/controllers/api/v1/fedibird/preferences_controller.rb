# frozen_string_literal: true

class Api::V1::Fedibird::PreferencesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:preferences' }, only: :show
  before_action -> { doorkeeper_authorize! :'write:preferences' }, only: :update
  before_action :require_user!
  after_action :set_private_no_store

  # Building params can raise ParseError before update runs. Only this PATCH
  # turns that into 422. json_body rescues JSON::ParserError and nothing else.
  rescue_from ActionDispatch::Http::Parameters::ParseError do |error|
    raise error unless action_name == 'update'

    render_invalid_body
  end

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
      raise UserPreferences::InvalidInput, invalid_body_error
    end

    raw = request.raw_post
    return {} if raw.blank?

    parsed = decode_json_object(raw)
    return parsed if parsed.is_a?(Hash)

    raise UserPreferences::InvalidInput, invalid_body_error
  end

  def decode_json_object(raw)
    ActiveSupport::JSON.decode(raw)
  rescue ActiveSupport::JSON.parse_error
    raise UserPreferences::InvalidInput, invalid_body_error
  end

  def invalid_body_error
    [{ 'key' => nil, 'code' => 'invalid_body' }]
  end

  def render_invalid_body
    render json: { error: 'Invalid preferences', errors: invalid_body_error }, status: 422
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
