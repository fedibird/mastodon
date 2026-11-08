# frozen_string_literal: true

class Api::V1::Fedibird::Emojis::ResolveController < Api::BaseController
  FIELDS = %w(emoji context).freeze

  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }
  before_action :require_user!
  after_action :private_cache_headers

  rescue_from EmojiReferences::Invalid do |error|
    render json: { error: 'Invalid emoji reference', errors: error.errors }, status: 422
  end

  rescue_from EmojiReferences::NotFound do
    render json: { error: 'Record not found' }, status: 404
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid emoji reference', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def create
    body = json_body
    invalid!('body', 'unknown_field') unless (body.keys - FIELDS).empty?
    invalid!('emoji', 'invalid_type') unless body['emoji'].is_a?(Hash)
    EmojiReferences::Context.new(current_user).authorize!(body['context'])
    render json: EmojiReferences::Resolver.new.resolve(body.fetch('emoji')).as_json
  end

  private

  def json_body
    invalid!('body', 'invalid_type') unless request.content_mime_type == Mime[:json]

    raw = request.raw_post
    invalid!('body', 'too_large') if raw.bytesize > PersonalEmojiSets::Definition::MAX_BODY_BYTES

    parsed = ActiveSupport::JSON.decode(raw)
    invalid!('body', 'invalid_type') unless parsed.is_a?(Hash)
    parsed
  rescue ActiveSupport::JSON.parse_error
    invalid!('body', 'invalid_json')
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end

  def private_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end
end
