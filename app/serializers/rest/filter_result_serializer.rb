# frozen_string_literal: true

class REST::FilterResultSerializer < ActiveModel::Serializer
  belongs_to :filter, serializer: REST::FilterSerializer
  has_many :keyword_matches
  has_many :status_matches
  attribute :tag_matches, if: -> { object.tag_matches.present? }

  def status_matches
    object.status_matches&.map(&:to_s)
  end
end
