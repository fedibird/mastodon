# frozen_string_literal: true

class Api::V1::Statuses::FavouritesController < Api::BaseController
  include Authorization

  before_action -> { doorkeeper_authorize! :write, :'write:favourites' }
  before_action :require_user!
  before_action :set_status, only: [:create]

  def create
    raise Mastodon::NotPermittedError if current_user.setting_disable_reactions

    FavouriteService.new.call(current_account, @status)
    render json: @status, serializer: REST::StatusSerializer
  end

  def destroy
    fav = current_account.favourites.find_by(status_id: params[:status_id])

    if fav
      @status = fav.status
      count = [@status.favourites_count - 1, 0].max
      UnfavouriteWorker.perform_async(current_account.id, @status.id)
    else
      @status = Status.include_expired.find(params[:status_id])
      authorize @status, :show?
      count = @status.favourites_count
    end

    relationships = StatusRelationshipsPresenter.new(
      [@status],
      current_account.id,
      favourites_map: { @status.id => false },
      attributes_map: { @status.id => { favourites_count: count } }
    )

    render json: @status, serializer: REST::StatusSerializer, relationships: relationships
  rescue Mastodon::NotPermittedError
    not_found
  end

  private

  def set_status
    @status = Status.include_expired.find(params[:status_id])
    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    not_found
  end
end
