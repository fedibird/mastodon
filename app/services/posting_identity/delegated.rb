# frozen_string_literal: true

class PostingIdentity::Delegated
  def self.build(delegation)
    account = delegation.posting_account

    PostingIdentity::Record.new(
      id: PostingIdentity.delegated_id(account),
      kind: PostingIdentity::DELEGATED_KIND,
      provider: PostingIdentity::LOCAL_PROVIDER,
      account: account,
      authorization: PostingIdentity::AUTHORIZATION_UNAVAILABLE,
      capabilities: PostingIdentity::CAPABILITIES.index_with { PostingIdentity::CAPABILITY_UNAVAILABLE },
      delegation: {
        state: 'active',
        scopes: Array(delegation.scopes),
        expires_at: delegation.expires_at,
        approved_at: delegation.approved_at,
      }
    )
  end
end
