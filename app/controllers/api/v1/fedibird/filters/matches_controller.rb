# frozen_string_literal: true

class Api::V1::Fedibird::Filters::MatchesController < Api::BaseController
  MAX_RESPONSE_BYTES = 1_048_576

  # Each invocation accepts alternative scopes (OR). Separate callbacks require
  # both capabilities, while the umbrella read scope satisfies either one.
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action -> { doorkeeper_authorize! :read, :'read:filters' }
  before_action :require_user!

  rescue_from JSON::ParserError, ActionDispatch::Http::Parameters::ParseError do
    render json: { error: 'Invalid JSON body' }, status: :bad_request
  end

  def create
    response.headers['Cache-Control'] = 'private, no-store'
    unless request.media_type == 'application/json'
      render json: { error: 'Expected application/json' }, status: :unsupported_media_type
      return
    end

    # Rails deep_munge removes nil array members. Validate the original JSON so
    # [null] and ["123", null] cannot silently become successful partial input.
    body = JSON.parse(request.raw_post)
    result = FilterMatchesService.new.call(current_account, body.is_a?(Hash) ? body['status_ids'] : nil).to_json
    raise Mastodon::ValidationError, 'Match response exceeds 1 MiB; request fewer status_ids' if result.bytesize > MAX_RESPONSE_BYTES

    render json: result
  end
end
