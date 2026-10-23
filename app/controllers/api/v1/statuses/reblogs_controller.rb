# frozen_string_literal: true

class Api::V1::Statuses::ReblogsController < Api::BaseController
  include Authorization

  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }
  before_action :require_user!
  before_action :set_reblog, only: [:create]
  before_action :set_circle, only: [:create], unless: :projection_target?

  override_rate_limit_headers :create, family: :statuses

  def create
    raise Mastodon::NotPermittedError if current_user.setting_disable_reactions

    return create_link_boost if projection_target?

    @status = ReblogService.new.call(current_account, @reblog, reblog_params)

    render json: @status, serializer: REST::StatusSerializer
  end

  def destroy
    @status = current_account.statuses.find_by(reblog_of_id: params[:status_id])

    if @status
      authorize @status, :unreblog?
      @reblog = @status.reblog
      count = [@reblog.reblogs_count - 1, 0].max
      @status.discard
      RemovalWorker.perform_async(@status.id)
    else
      @reblog = Status.find(params[:status_id])
      authorize @reblog, :show?
      return destroy_link_boost if projection_target?

      count = @reblog.reblogs_count
    end

    relationships = StatusRelationshipsPresenter.new(
      [@status],
      current_account.id,
      reblogs_map: { @reblog.id => false },
      attributes_map: { @reblog.id => { reblogs_count: count } }
    )

    render json: @reblog, serializer: REST::StatusSerializer, relationships: relationships
  rescue Mastodon::NotPermittedError
    not_found
  end

  private

  # E4-B. A projection is never handed to ReblogService. The owner's boost
  # becomes a share of the User's own link note, decided by the authenticated
  # User, not by the Account.
  def projection_target?
    @reblog.present? && ExternalBridge::ProjectionPrivacy.private_status?(@reblog)
  end

  def create_link_boost
    result = ExternalBridge::LinkSharing::Boost.call(
      user: current_user,
      status: @reblog,
      visibility: params[:visibility],
      circle_id: params[:circle_id]
    )

    render json: result.wrapper, serializer: REST::StatusSerializer
  rescue ExternalBridge::Error => e
    render_link_sharing_error(e)
  end

  def destroy_link_boost
    ExternalBridge::LinkSharing::Unboost.call(user: current_user, status: @reblog)

    relationships = StatusRelationshipsPresenter.new(
      [@reblog],
      current_account.id,
      reblogs_map: { @reblog.id => false },
      attributes_map: { @reblog.id => { reblogs_count: @reblog.reblogs_count } }
    )

    render json: @reblog, serializer: REST::StatusSerializer, relationships: relationships
  rescue Mastodon::NotPermittedError
    not_found
  rescue ExternalBridge::Error => e
    render_link_sharing_error(e)
  end

  def render_link_sharing_error(error)
    return not_found if error.code == 'not_owner'

    render json: { error: error.code }, status: error.http_status
  end

  def set_reblog
    @reblog = Status.find(params[:status_id])
    authorize @reblog, :show?
  rescue Mastodon::NotPermittedError
    not_found
  end

  def set_circle
    reblog_params[:circle] = begin
      if reblog_params[:visibility] == 'mutual'
        reblog_params[:visibility] = 'limited'
        current_account
      elsif reblog_params[:circle_id].blank?
        nil
      else
        current_account.owned_circles.find(reblog_params[:circle_id])
      end
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: I18n.t('statuses.errors.circle_not_found') }, status: 404
  end

  def reblog_params
    params.permit(:visibility, :circle_id)
  end
end
