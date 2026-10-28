# frozen_string_literal: true

class Api::V1::ExternalBridge::RSS::SubscriptionsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }, only: :index
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, except: :index
  before_action :require_user!

  def index
    rows = ExternalSubscription.where(user_id: current_user.id).includes(:external_source).order(id: :desc).limit(limit_param(40))
    render json: rows.map { |row| subscription_json(row) }
  end

  def create
    subscription = ExternalBridge::RSS::Subscribe.new.call(user: current_user, url: params[:url])
    status = incomplete_import?(subscription) ? 422 : 201
    render json: subscription_json(subscription), status: status
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  def pause
    subscription = ExternalBridge::RSS::Subscribe.new.pause!(user: current_user, subscription_id: params[:id])
    render json: subscription_json(subscription)
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  def resume
    subscription = ExternalBridge::RSS::Subscribe.new.resume!(user: current_user, subscription_id: params[:id])
    render json: subscription_json(subscription)
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  # 202 Accepted: the subscription is fenced and the removal is queued, not
  # finished. The body is the owner's progress record (the same one for a
  # repeated request); poll its `url` for the state. Earlier versions answered
  # 200 with {} after a synchronous delete.
  def destroy
    deletion = ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: current_user, subscription_id: params[:id])
    render json: ExternalBridge::RSS::SubscriptionDeletionPayload.call(deletion), status: 202
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  def restore
    subscription = ExternalBridge::RSS::Subscribe.new.restore!(
      user: current_user,
      subscription_id: params[:id],
      resource_id: params[:resource_id]
    )
    render json: subscription_json(subscription)
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  # Flags and language are optional. A missing key is left unchanged, which
  # is different from an explicit unspecified language. Any other key is
  # ignored. The row is saved before imported statuses are rewritten.
  def update
    subscription = ExternalBridge::RSS::PresentationUpdate.new.call(
      user: current_user,
      subscription_id: params[:id],
      media_sensitive: provided_flag(:media_sensitive),
      cw_enabled: provided_flag(:cw_enabled),
      language_mode: provided_flag(:language_mode),
      language: provided_flag(:language)
    )
    render json: subscription_json(subscription)
  rescue ExternalBridge::Error => e
    render json: { error: e.code }, status: e.http_status
  end

  private

  def incomplete_import?(subscription)
    subscription.failed_item_count.to_i.positive? && !subscription.external_status_projections.exists?
  end

  def subscription_json(subscription)
    source = subscription.external_source
    {
      id: subscription.id.to_s,
      state: subscription.state,
      last_error_code: subscription.last_error_code,
      failed_item_count: subscription.failed_item_count,
      retry_count: subscription.retry_count,
      next_retry_at: subscription.next_retry_at,
      checked_at: subscription.checked_at,
      source: {
        protocol: source.protocol,
        url: source.canonical_key,
        title: source.title,
        icon_url: ExternalBridge::RSS::Icon::Delivery.url(source),
      },
      presentation: {
        media_sensitive: subscription.media_sensitive,
        cw_enabled: subscription.cw_enabled,
        language_mode: subscription.language_mode,
        language: subscription.language,
        revision: subscription.presentation_revision.to_s,
        applied_revision: subscription.presentation_applied_revision.to_s,
        state: subscription.presentation_state,
      },
    }
  end

  def provided_flag(key)
    return ExternalBridge::RSS::PresentationUpdate::OMIT unless params.key?(key)

    params[key]
  end
end
