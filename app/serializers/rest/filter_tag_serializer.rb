# frozen_string_literal: true

class REST::FilterTagSerializer < ActiveModel::Serializer
  attributes :id, :name

  def id
    object.id.to_s
  end
end
