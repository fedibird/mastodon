# frozen_string_literal: true

class REST::FollowTagSerializer < ActiveModel::Serializer
  attributes :id, :name, :updated_at

  def id
    resource_id.to_s
  end

  private

  def resource_id
    if object.is_a?(TagFollowDelivery)
      object.legacy_resource_id
    else
      object.id
    end
  end
end
