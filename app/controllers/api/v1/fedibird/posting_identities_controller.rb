# frozen_string_literal: true

class Api::V1::Fedibird::PostingIdentitiesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }, only: :index
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, only: :interaction
  before_action :require_user!
  before_action :require_administrator!, only: :index
  before_action :reject_account_enumeration!

  def index
    render json: PostingIdentity::Catalog.new(current_user), serializer: REST::PostingIdentityCatalogSerializer
  end

  # Confirms a reply or quote for the selected sender. The response has
  # no status body, so it cannot be used to read a post the operator
  # cannot already see.
  def interaction
    resolution = PostingIdentity::SendGuard.resolve!(
      user: current_user,
      account_id: params[:account_id],
      posting_identity_id: params[:posting_identity_id],
      purpose: :create
    )
    raise Mastodon::NotPermittedError unless resolution.delegated?

    PostingIdentity::DelegatedTextPost.resolve!(
      resolution: resolution,
      viewer: current_account,
      params: interaction_params
    )
    head 204
  end

  private

  def require_administrator!
    raise Mastodon::NotPermittedError unless current_user&.can?(:administrator)
  end

  def reject_account_enumeration!
    raise Mastodon::NotPermittedError if params[:account_id].present? || params[:user_id].present?
  end

  def interaction_params
    params.permit(
      :status,
      :in_reply_to_id,
      :quote_id,
      :visibility,
      :spoiler_text,
      :posting_context_account_id,
      :posting_context_key,
      :posting_context_revision,
      :circle_id,
      :audience_account_id,
      :scheduled_at,
      :scheduled_in,
      :expires_at,
      :expires_in,
      media_ids: [],
      allowed_mentions: [],
      status_reference_ids: [],
      status_reference_urls: []
    )
  end
end
