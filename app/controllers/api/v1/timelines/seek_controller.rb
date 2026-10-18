# frozen_string_literal: true

class Api::V1::Timelines::SeekController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action -> { authorize_if_got_token! :read, :'read:lists' }, if: -> { params[:source].to_s == 'list' }
  before_action :require_user!, if: :require_user_for_source?

  def create
    render json: resolver.call(request_payload).to_h
  end

  private

  def resolver
    TimelineSeek::Resolver.new(current_account, user: current_user, application: doorkeeper_token&.application)
  end

  def require_user_for_source?
    %w(home limited list personal).include?(params[:source].to_s) || !Setting.timeline_preview
  end

  # POST body only. seek_target is filtered from logs. Raw search text is
  # rejected and never copied into the resolver payload.
  def request_payload
    permitted = params.permit(
      :version,
      :kind,
      :preference,
      :source,
      context: [
        :remote, :domain, :only_media, :without_media, :without_bot, :hashtag, :tagged, :id, :list_id, :group_id,
        :account_id, :exclude_replies, :exclude_reblogs,
        { visibilities: [] }, { any: [] }, { all: [] }, { none: [] }
      ],
      seek_target: [:id, :at, :account_id]
    )

    {
      version: permitted[:version],
      kind: permitted[:kind],
      preference: permitted[:preference],
      source: permitted[:source],
      context: permitted[:context]&.to_h,
      seek_target: permitted[:seek_target]&.to_h,
      reject_search_text: search_text_submitted?,
    }
  end

  def search_text_submitted?
    target = params[:seek_target]
    return false unless target.respond_to?(:key?)

    TimelineSeek::Resolver::SEARCH_TEXT_KEYS.any? { |key| target.key?(key) || target.key?(key.to_sym) }
  end
end
