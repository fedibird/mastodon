# frozen_string_literal: true

class PostingIdentity::Local
  def self.build(user)
    account = user&.account
    raise Mastodon::NotPermittedError if account.nil?

    ready = usable?(user)
    state = ready ? PostingIdentity::CAPABILITY_SUPPORTED : PostingIdentity::CAPABILITY_UNAVAILABLE

    PostingIdentity::Record.new(
      id: PostingIdentity.local_id(account),
      kind: PostingIdentity::LOCAL_KIND,
      provider: PostingIdentity::LOCAL_PROVIDER,
      account: account,
      authorization: ready ? PostingIdentity::AUTHORIZATION_READY : PostingIdentity::AUTHORIZATION_UNAVAILABLE,
      capabilities: PostingIdentity::CAPABILITIES.index_with { state }
    )
  end

  # A credential stored for the user is not authority to post. The signed-in
  # account can post only while the user is functional and posting is allowed.
  def self.usable?(user)
    return false if user.nil? || user.account.nil?
    return false unless user.functional?
    return false if user.account.suspended?
    return false if user.setting_disable_post

    true
  end
end
