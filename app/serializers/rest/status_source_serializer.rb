# frozen_string_literal: true

class REST::StatusSourceSerializer < ActiveModel::Serializer
  # Edit source stays canonical: `:foo::bar:` with no U+200B.
  # Display serializers insert that boundary separately.
  attributes :id, :text, :spoiler_text

  def id
    object.id.to_s
  end
end
