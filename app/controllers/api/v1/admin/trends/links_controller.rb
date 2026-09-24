# frozen_string_literal: true

class Api::V1::Admin::Trends::LinksController < Api::V1::Trends::LinksController
  include Authorization
  include ::Admin::PermissionsConcern

  before_action -> { doorkeeper_authorize! :'admin:read' }, only: :index
  before_action -> { doorkeeper_authorize! :'admin:write' }, except: :index

  after_action :verify_authorized, except: :index

  def index
    if can_manage_taxonomies?
      render json: @links, each_serializer: REST::Admin::Trends::LinkSerializer
    else
      super
    end
  end

  def approve
    authorize :preview_card, :review?

    link = PreviewCard.find(params[:id])
    link.update(trendable: true)
    render json: link, serializer: REST::Admin::Trends::LinkSerializer
  end

  def reject
    authorize :preview_card, :review?

    link = PreviewCard.find(params[:id])
    link.update(trendable: false)
    render json: link, serializer: REST::Admin::Trends::LinkSerializer
  end

  private

  def enabled?
    super || can_manage_taxonomies?
  end

  def can_manage_taxonomies?
    current_user&.functional? && current_user.can?(:manage_taxonomies)
  end

  def links_from_trends
    if can_manage_taxonomies?
      Trends.links.query
    else
      super
    end
  end
end
