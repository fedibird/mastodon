# frozen_string_literal: true

class PostingIdentity::SendGuard
  # call! is the signed-in account. Edits and deletes use it, so a delegated
  # id is rejected there. resolve! chooses the account for one purpose:
  # :session is the signed-in account, :create is a new post, :media_create
  # stores an upload, and :media_update reads or changes that upload.
  # A delegated account comes only from a grant held by the signed-in user.
  #
  # Status and media APIs do not take account_id as a sender. The web client
  # sends audience_account_id for a destination and omits account_id. Rejecting
  # a present account_id is an intentional Fedibird extension: ignoring it
  # would hide an attempt to choose another account.
  PURPOSES = %i(session create media_create media_update).freeze

  def self.call!(user:, account_id: nil, posting_identity_id: nil)
    resolve!(user: user, account_id: account_id, posting_identity_id: posting_identity_id, purpose: :session).account
  end

  def self.resolve!(user:, account_id: nil, posting_identity_id: nil, purpose: :session)
    raise Mastodon::NotPermittedError unless PURPOSES.include?(purpose)
    raise Mastodon::NotPermittedError if user.nil? || user.account.nil?
    raise Mastodon::NotPermittedError if account_id.present?

    identity_id = posting_identity_id.to_s.presence
    local_id = PostingIdentity.local_id(user.account)

    if identity_id.nil? || identity_id == local_id
      identity = PostingIdentity::Local.build(user)
      raise Mastodon::NotPermittedError unless identity.ready?

      return PostingIdentity::Resolution.new(account: user.account, identity_id: identity.id)
    end

    raise Mastodon::NotPermittedError if purpose == :session

    delegation = delegated_grant(user, identity_id)
    account = delegation&.posting_account
    raise Mastodon::NotPermittedError if delegation.nil? || account.nil? || !account.local?

    required_scopes(purpose).each do |operation|
      raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(
        grantee: user,
        delegation: delegation,
        operation: operation
      )
    end

    PostingIdentity::Resolution.new(
      account: account,
      identity_id: identity_id,
      delegation: delegation
    )
  end

  # A new post needs post. An upload or its later description also needs
  # media. Media without post is not enough to create or attach a file.
  def self.required_scopes(purpose)
    case purpose
    when :create
      ['post']
    when :media_create, :media_update
      %w(post media)
    else
      raise Mastodon::NotPermittedError
    end
  end
  private_class_method :required_scopes

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
