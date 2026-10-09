# frozen_string_literal: true

class PostingIdentity::Catalog
  include ActiveModel::Serialization

  # The catalog is the signed-in user's own account. It does not accept an
  # account id, and a stored external credential is not a posting grant.
  def self.model_name
    ActiveModel::Name.new(self, nil, 'PostingIdentityCatalog')
  end

  def initialize(user)
    @user = user
  end

  def default_identity_id
    identity.id
  end

  def identities
    [identity]
  end

  def identity
    @identity ||= PostingIdentity::Local.build(@user)
  end
end
