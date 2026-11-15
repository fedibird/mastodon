# frozen_string_literal: true

class Api::V1::HashtagMutesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:filters' }, only: :index
  before_action -> { doorkeeper_authorize! :write, :'write:filters' }, except: :index
  before_action :require_user!
  before_action :set_filter, only: [:update, :destroy]

  def index
    render json: hashtag_filters, each_serializer: REST::FilterSerializer, rules_requested: true
  end

  def create
    filter = HashtagMutes::UpsertService.new.call(current_account, name: mute_params[:name], expires_in: mute_params[:expires_in])
    render json: filter, serializer: REST::FilterSerializer, rules_requested: true
  end

  def update
    name = @filter.filter_tags.pick(:name)
    filter = HashtagMutes::UpsertService.new.call(
      current_account,
      name: name,
      expires_in: mute_params[:expires_in],
      preserve_expiry: preserve_expiry?
    )
    render json: filter, serializer: REST::FilterSerializer, rules_requested: true
  end

  def destroy
    HashtagMutes::RemoveService.new.call(@filter)
    render_empty
  end

  private

  def hashtag_filters
    current_account.custom_filters.joins(:filter_tags).includes(:keywords, :statuses, :filter_tags).distinct.order(:id)
  end

  def set_filter
    @filter = current_account.custom_filters.joins(:filter_tags).find(params[:id])
  end

  def mute_params
    params.permit(:name, :expires_in, :preserve_expiry)
  end

  def preserve_expiry?
    ActiveModel::Type::Boolean.new.cast(mute_params[:preserve_expiry])
  end
end
