# frozen_string_literal: true

class PostingIdentity::Catalog
  extend ActiveModel::Naming
  include ActiveModel::Serialization

  def initialize(user)
    @user = user
  end

  def default_identity_id
    local_identity&.id
  end

  def identities
    identity = local_identity
    identity ? [identity] : []
  end

  def identity_for(identity_id)
    return if identity_id.blank?

    identities.find { |identity| identity.id == identity_id.to_s }
  end

  private

  # M1 derives the only granted sender from the authenticated user.
  # Other local users, and external Mastodon, Misskey, or Bluesky
  # accounts, are not listed until that sender has its own grant.
  def local_identity
    return if @user&.account.nil?

    @local_identity ||= PostingIdentity::Local.new(@user)
  end
end
