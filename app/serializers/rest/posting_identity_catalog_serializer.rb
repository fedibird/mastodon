# frozen_string_literal: true

class REST::PostingIdentityCatalogSerializer < ActiveModel::Serializer
  attributes :default_identity_id, :identities

  def identities
    object.identities.map do |identity|
      REST::PostingIdentitySerializer.new(identity).as_json
    end
  end
end
