# frozen_string_literal: true

class Api::V1::FavouriteTagsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:favourite_tags' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :write, :'write:favourite_tags' }, except: [:index, :show]

  before_action :require_user!
  before_action :set_favourite_tag, except: [:index, :create]

  def index
    @favourite_tags = FavouriteTag.where(account: current_account).all
    render json: @favourite_tags, each_serializer: REST::FavouriteTagSerializer
  end

  def show
    render json: @favourite_tag, serializer: REST::FavouriteTagSerializer
  end

  def create
    existing = find_existing_favourite_tag(favourite_tag_params[:name])

    if existing
      render json: existing, serializer: REST::FavouriteTagSerializer
      return
    end

    @favourite_tag = FavouriteTag.create!(favourite_tag_params.merge(account: current_account))
    render json: @favourite_tag, serializer: REST::FavouriteTagSerializer
  end

  def update
    @favourite_tag.update!(favourite_tag_params)
    render json: @favourite_tag, serializer: REST::FavouriteTagSerializer
  end

  def destroy
    @favourite_tag.destroy!
    render_empty
  end

  private

  def set_favourite_tag
    @favourite_tag = FavouriteTag.where(account: current_account).find(params[:id])
  end

  def favourite_tag_params
    params.permit(:name)
  end

  def find_existing_favourite_tag(name)
    normalized = HashtagNormalizer.new.normalize(name.to_s)
    return if normalized.blank?

    current_account.favourite_tags.includes(:tag).find do |favourite|
      HashtagNormalizer.new.normalize(favourite.name.to_s) == normalized
    end
  end
end
