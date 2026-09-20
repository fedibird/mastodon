# frozen_string_literal: true

class Api::V1::FollowTagsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:follows' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :write, :'write:follows' }, except: [:index, :show]

  before_action :require_user!
  before_action :set_follow_tag_delivery, only: [:show, :update, :destroy]

  def index
    @follow_tags = TagFollowDelivery.for_account(current_account).includes(tag_follow: :tag)
    render json: @follow_tags, each_serializer: REST::FollowTagSerializer
  end

  def show
    render json: @follow_tag, serializer: REST::FollowTagSerializer
  end

  def create
    @follow_tag = tag_follow_delivery_writer.create!(
      account: current_account,
      name: follow_tag_params[:name],
      media_only: follow_tag_params.fetch(:media_only, false)
    )
    render json: @follow_tag, serializer: REST::FollowTagSerializer
  end

  def update
    @follow_tag = tag_follow_delivery_writer.update!(update_writer_params)
    render json: @follow_tag, serializer: REST::FollowTagSerializer
  end

  def destroy
    tag_follow_delivery_writer.destroy!(
      account: current_account,
      legacy_resource_id: params[:id]
    )
    render_empty
  end

  private

  def set_follow_tag_delivery
    @follow_tag = TagFollowDelivery.for_account(current_account).find_by!(legacy_follow_tag_id: params[:id])
  end

  def follow_tag_params
    params.permit(:name, :media_only)
  end

  def update_writer_params
    attrs = {
      account: current_account,
      legacy_resource_id: params[:id],
    }
    attrs[:name] = follow_tag_params[:name] if follow_tag_params.key?(:name)
    attrs[:media_only] = follow_tag_params[:media_only] if follow_tag_params.key?(:media_only)
    attrs
  end

  def tag_follow_delivery_writer
    HashtagUnification::TagFollowDeliveryWriter.new
  end
end
