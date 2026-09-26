# frozen_string_literal: true

class REST::ListSerializer < ActiveModel::Serializer
  attributes :id, :title, :replies_policy, :favourite, :exclusive

  def id
    object.id.to_s
  end

  # Fedibird treats Home and lists as independent destinations, so Mastodon's
  # exclusive-list Home suppression is intentionally unsupported.
  def exclusive
    false
  end
end
