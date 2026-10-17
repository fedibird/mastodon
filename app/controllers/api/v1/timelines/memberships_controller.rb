# frozen_string_literal: true

class Api::V1::Timelines::MembershipsController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action -> { authorize_if_got_token! :read, :'read:lists' }, if: -> { params[:source].to_s == 'list' }
  before_action :require_user!, if: :require_user_for_source?

  def create
    render json: classifier.call(request_payload).to_h
  end

  private

  def classifier
    TimelineSeek::Membership.new(current_account, user: current_user, application: doorkeeper_token&.application)
  end

  def require_user_for_source?
    %w(home limited list personal).include?(params[:source].to_s) || !Setting.timeline_preview
  end

  # POST body only. ids and search-text keys are filtered from logs. Raw
  # search text is rejected and is not copied into the classifier payload.
  def request_payload
    if search_text_submitted?(params)
      return { version: params[:version], source: params[:source], reject_search_text: true }
    end

    permitted = params.permit(
      :version,
      :source,
      context: [
        :remote, :domain, :only_media, :without_media, :without_bot, :hashtag, :tagged, :id, :list_id, :group_id,
        { visibilities: [] }, { any: [] }, { all: [] }, { none: [] }
      ],
      ids: []
    )

    {
      version: permitted[:version],
      source: permitted[:source],
      context: permitted[:context]&.to_h,
      ids: permitted[:ids],
    }
  end

  def search_text_submitted?(value)
    case value
    when ActionController::Parameters, Hash
      value.keys.any? { |key| TimelineSeek::Resolver::SEARCH_TEXT_KEYS.include?(key.to_s) } || value.each_value.any? { |child| search_text_submitted?(child) }
    when Array
      value.any? { |child| search_text_submitted?(child) }
    else
      false
    end
  end
end
