# frozen_string_literal: true

class Api::V1::Fedibird::EmojiMutePreferencesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:mutes' }, only: :show
  before_action -> { doorkeeper_authorize! :write, :'write:mutes' }, only: :update
  before_action :require_user!
  after_action :private_cache_headers

  rescue_from EmojiMutes::Invalid do |error|
    render json: { error: 'Invalid emoji mute preference', errors: error.errors }, status: 422
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid emoji mute preference', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def show
    render json: EmojiMutes::Preference.new(current_user).as_json
  end

  def update
    body = json_body
    invalid!('body', 'unknown_field') unless (body.keys - %w(enabled)).empty?
    invalid!('enabled', 'invalid_type') unless body['enabled'] == true || body['enabled'] == false

    saved = EmojiMutes::Preference.new(current_user).update!(body['enabled'])
    # A failed write raises. Never report success from a default or a stale cache.
    invalid!('enabled', 'not_saved') unless saved['explicit'] == true && saved['enabled'] == body['enabled']

    render json: saved
  end

  private

  def json_body
    invalid!('body', 'invalid_type') unless request.content_mime_type == Mime[:json]

    raw = request.raw_post
    parsed = raw.present? ? ActiveSupport::JSON.decode(raw) : nil
    invalid!('body', 'invalid_type') unless parsed.is_a?(Hash)
    parsed
  rescue ActiveSupport::JSON.parse_error
    invalid!('body', 'invalid_json')
  end

  def invalid!(path, code)
    raise EmojiMutes::Invalid.new(path, code)
  end

  def private_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end
end
