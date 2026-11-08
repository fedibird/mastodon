# frozen_string_literal: true

class Api::V1::Fedibird::EmojiMutesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:mutes' }, only: :index
  before_action -> { doorkeeper_authorize! :write, :'write:mutes' }, only: [:create, :update, :destroy]
  before_action :require_user!
  before_action :set_mute, only: [:update, :destroy]
  after_action :private_cache_headers

  rescue_from EmojiMutes::Invalid, EmojiReferences::Invalid do |error|
    render json: { error: 'Invalid emoji mute', errors: error.errors }, status: 422
  end

  rescue_from EmojiMutes::Conflict do |error|
    render json: { error: error.message, errors: [{ path: error.path, code: error.code }] }, status: 409
  end

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid emoji mute', errors: [{ path: 'body', code: 'invalid_json' }] }, status: 422
  end

  def index
    revision = EmojiMutes::RuleSet.revision_for(current_account.id)
    write_collection_etag(revision)
    return if performed?

    mutes = current_account.emoji_mutes.order(:id).to_a
    render json: EmojiMutes::Document.collection(mutes, revision, EmojiMutes::Availability.new(mutes))
  end

  def create
    mute = EmojiMutes::Save.new.create(current_account, json_body)
    render json: EmojiMutes::Document.item(mute, EmojiMutes::Availability.new([mute])), status: 201
    write_collection_etag(EmojiMutes::RuleSet.revision_for(current_account.id))
  end

  def update
    mute = EmojiMutes::Save.new.update(current_account, @mute, json_body, if_match: request.headers['If-Match'])
    render json: EmojiMutes::Document.item(mute, EmojiMutes::Availability.new([mute]))
    write_collection_etag(EmojiMutes::RuleSet.revision_for(current_account.id))
  end

  def destroy
    revision = EmojiMutes::Save.new.destroy(current_account, @mute, expected: destroy_revision, if_match: request.headers['If-Match'])
    render json: { id: @mute.id.to_s, revision: revision }
    write_collection_etag(revision)
  end

  private

  def set_mute
    @mute = current_account.emoji_mutes.find(params[:id])
  end

  def write_collection_etag(revision)
    etag = EmojiMutes::Etags.collection(current_account.id, revision)
    response.headers['ETag'] = etag
    return unless action_name == 'index' && none_match?(etag)

    head :not_modified
  end

  def none_match?(etag)
    values = Array(request.if_none_match) + request.headers['If-None-Match'].to_s.split(',')
    values.any? { |value| EmojiMutes::Etags.match?(value, etag) }
  end

  def json_body
    invalid!('body', 'invalid_type') unless request.content_mime_type == Mime[:json]

    raw = request.raw_post
    invalid!('body', 'too_large') if raw.bytesize > EmojiMutes::MAX_BODY_BYTES
    parsed = ActiveSupport::JSON.decode(raw)
    invalid!('body', 'invalid_type') unless parsed.is_a?(Hash)
    parsed
  rescue ActiveSupport::JSON.parse_error
    invalid!('body', 'invalid_json')
  end

  def destroy_revision
    from_body = destroy_body_revision
    from_query = destroy_query_revision
    invalid!('expected_revision', 'invalid_revision') if from_body.nil? && from_query.nil?
    invalid!('expected_revision', 'invalid_revision') if from_body && from_query && from_body != from_query

    from_body || from_query
  end

  def destroy_body_revision
    return if request.raw_post.blank?
    return unless request.content_mime_type == Mime[:json]

    body = json_body
    invalid!('body', 'unknown_field') unless (body.keys - %w(expected_revision)).empty?
    invalid!('expected_revision', 'invalid_revision') unless body['expected_revision'].is_a?(Integer)

    body['expected_revision']
  end

  def destroy_query_revision
    value = request.query_parameters['expected_revision']
    return if value.nil?
    invalid!('expected_revision', 'invalid_revision') unless value.is_a?(String) && value.match?(/\A[0-9]+\z/)

    value.to_i
  end

  def invalid!(path, code)
    raise EmojiMutes::Invalid.new(path, code)
  end

  def private_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end
end
