# frozen_string_literal: true

class PostingIdentity::SubmissionAccount
  # Future status and media paths must resolve the sender through here
  # before calling PostStatusService or creating a media attachment.
  # The account argument those services receive is the return value,
  # never an Account looked up from a client account_id.
  def self.resolve!(user, identity_id)
    raise Mastodon::NotPermittedError unless user

    identity = PostingIdentity::Catalog.new(user).identity_for(identity_id)
    raise Mastodon::NotPermittedError unless identity&.postable?
    raise Mastodon::NotPermittedError unless identity.account.id == user.account_id

    user.account
  end
end
