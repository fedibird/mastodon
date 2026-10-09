# frozen_string_literal: true

class PostingIdentity::SendGuard
  # Future send paths must call this again. call! is the session-account
  # path used by media and status edits: a delegated id is rejected there.
  # resolve!(purpose: :create) is the only path that can return another
  # local account, and only from a grant held by the signed-in user.
  #
  # Status and media APIs do not take account_id as a sender. The web client
  # sends audience_account_id for a destination and omits account_id. Rejecting
  # a present account_id is an intentional Fedibird extension: ignoring it
  # would hide an attempt to choose another account.
  def self.call!(user:, account_id: nil, posting_identity_id: nil)
    resolve!(user: user, account_id: account_id, posting_identity_id: posting_identity_id, purpose: :session).account
  end

  def self.resolve!(user:, account_id: nil, posting_identity_id: nil, purpose: :session)
    raise Mastodon::NotPermittedError if user.nil? || user.account.nil?
    raise Mastodon::NotPermittedError if account_id.present?

    identity_id = posting_identity_id.to_s.presence
    local_id = PostingIdentity.local_id(user.account)

    if identity_id.nil? || identity_id == local_id
      identity = PostingIdentity::Local.build(user)
      raise Mastodon::NotPermittedError unless identity.ready?

      return PostingIdentity::Resolution.new(account: user.account, identity_id: identity.id)
    end

    raise Mastodon::NotPermittedError unless purpose == :create

    delegation = delegated_grant(user, identity_id)
    raise Mastodon::NotPermittedError if delegation.nil?
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(
      grantee: user,
      delegation: delegation,
      operation: 'post'
    )

    PostingIdentity::Resolution.new(
      account: delegation.posting_account,
      identity_id: identity_id,
      delegation: delegation
    )
  end

  # The numeric suffix is compared with grants this user already holds.
  # It is not used to load an Account on its own.
  def self.delegated_grant(user, identity_id)
    PostingIdentityDelegation.for_grantee(user).occupying_slot.includes(:grantor_user, :posting_account).find do |delegation|
      account = delegation.posting_account
      account && PostingIdentity.delegated_id(account) == identity_id
    end
  end
  private_class_method :delegated_grant
end
