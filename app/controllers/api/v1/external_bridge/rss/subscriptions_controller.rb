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
    }
  end
end
