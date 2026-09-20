# frozen_string_literal: true

class Form::FollowTag
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :id, :integer
  attribute :name, :string
  attribute :list_id, :integer
  attribute :media_only, :boolean, default: false

  validates :name, presence: true

  def self.model_name
    ::FollowTag.model_name
  end

  def self.from_delivery(delivery)
    new(
      id: delivery.legacy_resource_id,
      name: delivery.name,
      list_id: delivery.list_id,
      media_only: delivery.media_only
    )
  end

  def persisted?
    id.present?
  end
end
