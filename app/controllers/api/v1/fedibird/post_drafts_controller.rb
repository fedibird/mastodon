# frozen_string_literal: true

class Api::V1::Fedibird::PostDraftsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :'read:post_drafts' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :'write:post_drafts' }, only: [:create, :update, :destroy]
  before_action :require_user!
  after_action :set_private_no_store

  rescue_from ActionDispatch::Http::Parameters::ParseError, PostDrafts::Payload::Invalid do |error|
    errors = error.is_a?(PostDrafts::Payload::Invalid) ? error.errors : [{ 'code' => 'invalid_body', 'key' => nil }]
    render_invalid(errors)
  end

  def index
    page = PostDrafts::Page.new(current_account, params)
    rows = page.records
    set_pagination_headers(next_path(rows, page))
    response.headers['X-Post-Draft-Limit'] = PostDraft::LIMIT.to_s
    response.headers['X-Post-Draft-Count'] = owned_drafts.count.to_s
    render json: rows.map { |row| presenter.preview(row) }
  end

  def show
    render json: presenter.one(owned_draft)
  end

  def create
    render_result(store.create(client_uuid: json_body['client_uuid'], payload: json_body['payload']), created: :created)
  end

  def update
    render_result(
      store.update(params[:id], expected_revision: json_body['expected_revision'], payload: json_body['payload']),
      created: :updated
    )
  end

  def destroy
    render_destroy(store.destroy(params[:id], expected_revision: json_body['expected_revision']))
  end

  private

  def current_account
    current_user.account
  end

  def owned_drafts
    PostDraft.where(account_id: current_account.id)
  end

  def owned_draft
    owned_drafts.find(params[:id])
  end

  def store
    PostDrafts::Store.new(current_account)
  end

  def presenter
    PostDrafts::Presenter.new
  end

  def render_result(result, created:)
    case result.status
    when created
      render json: presenter.one(result.draft), status: created == :created ? 201 : 200
    when :existing
      render json: presenter.one(result.draft), status: 200
    when :conflict
      render json: conflict_body(result.draft), status: 409
    when :limit
      render json: { error: 'Draft limit reached', code: 'limit_reached', limit: PostDraft::LIMIT }, status: 422
    when :missing
      render_missing
    when :invalid
      render_invalid(result.error.errors)
    end
  end

  def conflict_body(draft)
    {
      error: 'Draft conflict',
      draft_id: draft.id.to_s,
      revision: draft.revision,
      updated_at: draft.updated_at.iso8601,
    }
  end

  def render_destroy(result)
    case result.status
    when :deleted
      render_empty
    when :conflict
      render json: conflict_body(result.draft), status: 409
    when :missing
      render_missing
    when :invalid
      render_invalid(result.error.errors)
    end
  end

  def render_missing
    render json: { error: 'Record not found' }, status: 404
  end

  def render_invalid(errors)
    render json: { error: 'Invalid draft', errors: errors }, status: 422
  end

  def next_path(rows, page)
    return unless page.more?

    api_v1_fedibird_post_drafts_url(limit: page.limit, max_id: rows.last.id)
  end

  def json_body
    @json_body ||= decode_json_body
  end

  def decode_json_body
    unless request.content_mime_type == Mime[:json]
      raise PostDrafts::Payload::Invalid, [{ 'code' => 'invalid_body', 'key' => nil }]
    end

    raw = request.raw_post
    return {} if raw.blank?

    parsed = JSON.parse(raw)
    return parsed if parsed.is_a?(Hash)

    raise PostDrafts::Payload::Invalid, [{ 'code' => 'invalid_body', 'key' => nil }]
  rescue JSON::ParserError, PostDrafts::Payload::Invalid
    raise PostDrafts::Payload::Invalid, [{ 'code' => 'invalid_body', 'key' => nil }]
  end

  def set_private_no_store
    response.headers['Cache-Control'] = 'private, no-store'
  end
end
