# frozen_string_literal: true

class Api::V1::EmojiSets::Personal::ItemsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :write, :'write:accounts' }
  before_action :require_user!
  after_action :private_cache_headers

  rescue_from PersonalEmojiSets::Invalid, EmojiReferences::Invalid do |error|
    render json: { error: 'Invalid personal emoji set', errors: error.errors }, status: 422
  end

  rescue_from PersonalEmojiSets::Conflict do
    render json: { error: 'Personal emoji set changed', code: 'conflict' }, status: 409
  end

  rescue_from PersonalEmojiSets::CategoryNotFound do
    render json: { error: 'Personal emoji category not found', code: 'category_not_found' }, status: 404
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid personal emoji set', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def create
    result = PersonalEmojiSets::AddItem.new(current_user).call(json_body, category_id: params[:category_id])
    render json: result.as_json
  end

  private

  def json_body
    raise PersonalEmojiSets::Invalid.new('body', 'invalid_type') unless request.content_mime_type == Mime[:json]

    raw = request.raw_post
    raise PersonalEmojiSets::Invalid.new('body', 'too_large') if raw.bytesize > PersonalEmojiSets::Definition::MAX_BODY_BYTES

    parsed = ActiveSupport::JSON.decode(raw)
    raise PersonalEmojiSets::Invalid.new('body', 'invalid_type') unless parsed.is_a?(Hash)
    parsed
  rescue ActiveSupport::JSON.parse_error
    raise PersonalEmojiSets::Invalid.new('body', 'invalid_json')
  end

  def private_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end
end
