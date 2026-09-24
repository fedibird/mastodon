# frozen_string_literal: true

class Api::V1::Admin::Trends::StatusesController < Api::V1::Trends::StatusesController
  include Authorization
  include ::Admin::PermissionsConcern

  before_action -> { doorkeeper_authorize! :'admin:read' }, only: :index
  before_action -> { doorkeeper_authorize! :'admin:write' }, except: :index

  after_action :verify_authorized, except: :index

  def index
    if can_manage_taxonomies?
      render json: @statuses, each_serializer: REST::Admin::Trends::StatusSerializer
    else
      super
    end
  end

  def approve
    authorize [:admin, :status], :review?

    status = Status.find(params[:id])
    status.update(trendable: true)
    render json: status, serializer: REST::Admin::Trends::StatusSerializer
  end

  def reject
    authorize [:admin, :status], :review?

    status = Status.find(params[:id])
    status.update(trendable: false)
    render json: status, serializer: REST::Admin::Trends::StatusSerializer
  end

  private

  def enabled?
    super || can_manage_taxonomies?
  end

  def can_manage_taxonomies?
    current_user&.functional? && current_user.can?(:manage_taxonomies)
  end

  def statuses_from_trends
    if can_manage_taxonomies?
      Trends.statuses.query
    else
      super
    end
  end
end
