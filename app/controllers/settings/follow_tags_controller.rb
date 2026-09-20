# frozen_string_literal: true

class Settings::FollowTagsController < Settings::BaseController
  layout 'admin'

  before_action :authenticate_user!
  before_action :set_lists, only: [:index, :new, :create, :edit, :update]
  before_action :set_follow_tags, only: :index
  before_action :set_follow_tag_delivery, only: [:edit, :update, :destroy]

  def index
    @follow_tag = Form::FollowTag.new
  end

  def new
    @follow_tag = Form::FollowTag.new
  end

  def create
    @follow_tag = Form::FollowTag.new(resource_params.to_h)
    persist_delivery(:create) ? redirect_to(settings_follow_tags_path) : render_create_failure
  end

  def edit; end

  def update
    @follow_tag.assign_attributes(resource_params.to_h)
    persist_delivery(:update) ? redirect_to(settings_follow_tags_path) : render(:edit)
  end

  def destroy
    tag_follow_delivery_writer.destroy!(
      account: current_account,
      legacy_resource_id: params[:id]
    )
    redirect_to settings_follow_tags_path
  rescue HashtagUnification::TagFollowDeliveryWriter::InconsistentLegacyShadowError
    unprocessable_entity
  end

  private

  def set_follow_tag_delivery
    delivery = TagFollowDelivery.for_account(current_account)
                                .find_by!(legacy_follow_tag_id: params[:id])
    @follow_tag = Form::FollowTag.from_delivery(delivery)
  end

  def set_follow_tags
    @follow_tags = TagFollowDelivery.for_account(current_account)
                                    .includes(:list, tag_follow: :tag)
                                    .order(Arel.sql('tag_follow_deliveries.list_id NULLS FIRST, tag_follow_deliveries.updated_at'))
                                    .page(params[:page])
                                    .per(40)
  end

  def set_lists
    @lists = List.where(account: current_account).all
  end

  def persist_delivery(action)
    return false unless @follow_tag.valid?

    case action
    when :create
      tag_follow_delivery_writer.create!(**writer_attributes)
    when :update
      tag_follow_delivery_writer.update!(**writer_attributes, legacy_resource_id: params[:id])
    end

    true
  rescue ActiveRecord::RecordInvalid => e
    assign_record_errors(e)
    false
  rescue ActiveRecord::RecordNotUnique
    @follow_tag.errors.add(:base, 'Duplicate record')
    false
  rescue HashtagUnification::TagFollowDeliveryWriter::InconsistentLegacyShadowError => e
    @follow_tag.errors.add(:base, e.message)
    false
  end

  def writer_attributes
    {
      account: current_account,
      name: @follow_tag.name,
      list: resolved_list,
      media_only: @follow_tag.media_only,
    }
  end

  def resolved_list
    list_id = @follow_tag.list_id
    return if list_id.blank?

    if list_id == -1
      List.find_or_create_by!(account: current_account, title: @follow_tag.name)
    else
      List.where(account: current_account).find(list_id)
    end
  end

  def assign_record_errors(error)
    if error.record.is_a?(Tag) && error.record.errors[:name].any?
      error.record.errors[:name].each { |message| @follow_tag.errors.add(:name, message) }
    else
      error.record.errors.full_messages.each { |message| @follow_tag.errors.add(:base, message) }
    end
  end

  def render_create_failure
    render :new
  end

  def resource_params
    params.require(:follow_tag).permit(:name, :list_id, :media_only)
  end

  def tag_follow_delivery_writer
    HashtagUnification::TagFollowDeliveryWriter.new
  end
end
