# frozen_string_literal: true

class PostingIdentity::SendGuard
  # Future send paths must call this again. The returned account is always
  # the authenticated user's account. A client account id is never loaded.
  #
  # Status and media APIs do not take account_id as a sender. The web client
  # sends audience_account_id for a destination and omits account_id. Rejecting
  # a present account_id is an intentional Fedibird extension: ignoring it
  # would hide an attempt to choose another account.
  def self.call!(user:, account_id: nil, posting_identity_id: nil)
    raise Mastodon::NotPermittedError if user.nil? || user.account.nil?
    raise Mastodon::NotPermittedError if account_id.present?

    if posting_identity_id.present?
      identity = PostingIdentity::Local.build(user)
      raise Mastodon::NotPermittedError unless posting_identity_id.to_s == identity.id
      raise Mastodon::NotPermittedError unless identity.ready?
    end

    user.account
  end
end
