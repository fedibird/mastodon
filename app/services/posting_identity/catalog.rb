# frozen_string_literal: true

class PostingIdentity::Catalog
  include ActiveModel::Serialization

  # The catalog is the signed-in user's own account plus delegations that
  # user has received. It does not accept an account id. A delegation is
  # listed as not ready to send until a later stage turns sending on.
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
    [identity] + delegated_identities
  end

  def identity
    @identity ||= PostingIdentity::Local.build(@user)
  end

  private

  def delegated_identities
    PostingIdentityDelegation.for_grantee(@user).occupying_slot.includes(:grantor_user, :posting_account).filter_map do |delegation|
      next unless PostingIdentity::DelegationResolver.relationship_active?(grantee: @user, delegation: delegation)

      PostingIdentity::Delegated.build(delegation)
    end
  end
end
