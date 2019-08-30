# frozen_string_literal: true

class Settings::FollowTagsController < Settings::BaseController
  layout 'admin'

  before_action :authenticate_user!
  before_action :set_follow_tags, only: :index
  before_action :set_follow_tag, except: [:index, :create]

  def index
    @follow_tag = FollowTag.new
  end

  def create
    @follow_tag = current_account.follow_tags.new(follow_tag_params)

    if @follow_tag.save
      redirect_to settings_follow_tags_path
    else
      set_follow_tags

      render :index
    end
  end

  def destroy
    @follow_tag.destroy!
    redirect_to settings_follow_tags_path
  end

  private

  def set_follow_tag
    @follow_tag = current_account.follow_tags.find(params[:id])
  end

  def set_follow_tags
    @follow_tags = current_account.follow_tags.order(:updated_at).reject(&:new_record?)
  end

  def follow_tag_params
    params.require(:follow_tag).permit(:name)
  end
end
