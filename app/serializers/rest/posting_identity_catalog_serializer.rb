# frozen_string_literal: true

class REST::PostingIdentityCatalogSerializer < ActiveModel::Serializer
  attributes :default_identity_id

  has_many :identities, serializer: REST::PostingIdentitySerializer
end
