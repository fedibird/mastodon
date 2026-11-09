# frozen_string_literal: true

class Api::V1::Fedibird::EmojiMutesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:mutes' }, only: :index
  before_action -> { doorkeeper_authorize! :write, :'write:mutes' }, except: :index
  before_action :require_user!
  before_action :set_emoji_mute, only: [:update, :destroy]
  after_action :private_cache_headers

  rescue_from EmojiMutes::Invalid, EmojiReferences::Invalid do |error|
    render json: { error: 'Invalid emoji mute', errors: error.errors }, status: 422
  end

  rescue_from EmojiMutes::Conflict do |error|
    render json: { error: 'Emoji mute conflict', errors: [{ path: 'emoji_mute', code: error.code }] }, status: 409
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid emoji mute', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def index
    mutes, revision = EmojiMutes::Repository.consistent_state(current_user.id)
    etag = collection_etag(revision)
    response.headers['ETag'] = etag
    if none_match?(etag)
      head 304
      return
    end

    render json: EmojiMutes::Presenter.new(mutes).list(revision)
  end

  def create
    body = json_body
    payload = EmojiMutes::Repository.new(current_user).create(body)
    response.headers['ETag'] = item_etag(payload.dig('emoji_mute', 'id'), payload.dig('emoji_mute', 'revision'))
    render json: payload, status: 201
  end

  def update
    body = json_body
    payload = EmojiMutes::Repository.new(current_user).update(@emoji_mute, body, if_match_revision: if_match_revision)
    response.headers['ETag'] = item_etag(payload.dig('emoji_mute', 'id'), payload.dig('emoji_mute', 'revision'))
    render json: payload
  end

  def destroy
    body = request.raw_post.present? ? json_body : {}
    invalid!('body', 'unknown_field') unless (body.keys - %w(expected_revision)).empty?
    payload = EmojiMutes::Repository.new(current_user).destroy(
      @emoji_mute,
      expected_revision: body['expected_revision'],
      if_match_revision: if_match_revision
    )
    render json: payload
  end

  private

  def set_emoji_mute
    @emoji_mute = EmojiMute.find_by!(id: params[:id], user_id: current_user.id)
  end

  def json_body
    invalid!('body', 'invalid_type') unless request.content_mime_type == Mime[:json]

    raw = request.raw_post
    invalid!('body', 'too_large') if raw.bytesize > EmojiMute::MAX_BODY_BYTES
    parsed = ActiveSupport::JSON.decode(raw)
    invalid!('body', 'invalid_type') unless parsed.is_a?(Hash)
    parsed
  rescue ActiveSupport::JSON.parse_error
    invalid!('body', 'invalid_json')
  end

  def if_match_revision
    header = request.headers['If-Match']
    return nil if header.blank?

    matched = header.match(/\A(?:W\/)?"#{Regexp.escape(@emoji_mute.id.to_s)}-(\d+)"\z/)
    invalid!('If-Match', 'invalid_type') unless matched
    matched[1]
  end

  def collection_etag(revision)
    %(W/"emoji-mutes-#{revision}")
  end

  def item_etag(id, revision)
    %("#{id}-#{revision}")
  end

  def none_match?(etag)
    Array(request.if_none_match).any? { |tag| tag.to_s == etag || tag.to_s == etag.delete_prefix('W/') }
  end

  def invalid!(path, code)
    raise EmojiMutes::Invalid.new(path, code)
  end

  def private_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end
end
