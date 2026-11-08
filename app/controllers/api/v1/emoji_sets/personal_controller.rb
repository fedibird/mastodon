# frozen_string_literal: true

class Api::V1::EmojiSets::PersonalController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }, only: [:show, :stock, :resolve]
  before_action -> { doorkeeper_authorize! :write, :'write:accounts' }, only: :update
  before_action :require_user!
  after_action :private_cache_headers

  rescue_from PersonalEmojiSets::Invalid do |error|
    render json: { error: 'Invalid personal emoji set', errors: error.errors }, status: 422
  end

  rescue_from PersonalEmojiSets::Conflict do
    render json: { error: 'Personal emoji set changed', code: 'conflict' }, status: 409
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do |error|
    raise error unless %w(update resolve).include?(action_name)

    render json: { error: 'Invalid personal emoji set', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def show
    render json: PersonalEmojiSets::Document.read(current_user).as_json
  end

  def stock
    document = PersonalEmojiSets::Document.read(current_user)
    render json: document.stock_document if stale?(etag: document.etag(current_user.id), public: false)
  end

  def update
    render json: PersonalEmojiSets::Save.new(current_user).call(json_body).as_json
  end

  # Resolve a new selection before it enters the editor draft. In particular,
  # pin a custom emoji's database identity now, not its shortcode at a later
  # save when a deleted shortcode may have been registered again.
  def resolve
    body = json_body
    allowed = %w(kind shortcode native)
    raise PersonalEmojiSets::Invalid.new('body', 'unknown_field') unless (body.keys - allowed).empty?

    category = {
      'id' => 'resolve',
      'name' => 'resolve',
      'items' => [body.merge('id' => 'resolve-item')],
    }
    validated = PersonalEmojiSets::Definition.new([category]).validate!
    item = validated.first.fetch('items').first
    resolved = PersonalEmojiSets::Stock.new(validated).resolved_items.fetch(item.fetch('id'))
    raise PersonalEmojiSets::Invalid.new('body', 'unavailable_emoji') unless resolved.fetch(:available)

    render json: { item: item.except('id'), resolved: resolved }
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
    response.headers['Cache-Control'] = action_name == 'stock' && [200, 304].include?(response.status) ? 'private, no-cache' : 'private, no-store'
  end
end
