# frozen_string_literal: true

class Api::V1::ExternalBridge::RSS::Subscriptions::StatusesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action :require_user!

  def index
    subscription = ExternalSubscription.not_deleting.find_by(id: params[:subscription_id], user_id: current_user.id)
    return render(json: { error: 'not_found' }, status: 404) if subscription.nil?

    scope = ExternalStatusProjection.where(user_id: current_user.id, external_subscription_id: subscription.id)
    scope = scope.where(ExternalStatusProjection.arel_table[:id].lt(params[:max_id].to_i)) if params[:max_id].present?
    rows = scope.includes(status: [], external_resource: :external_source).order(id: :desc).limit(limit_param(20))
    ActiveRecord::Associations::Preloader.new.preload(rows.map(&:status), :external_status_projection)
    render json: rows.map { |row| item_json(row) }
  end

  private

  def item_json(row)
    resource = row.external_resource
    {
      id: row.status_id.to_s,
      projection_id: row.id.to_s,
      title: resource&.title,
      canonical_url: resource&.canonical_url,
      byline_name: resource&.byline,
      source_title: resource&.external_source&.title,
      published_at: resource&.published_at,
      source_deleted: row.source_deleted,
      revision: resource&.revision,
    }
  end
end
