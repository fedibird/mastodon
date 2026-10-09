# frozen_string_literal: true

class PostingIdentity::Delegated
  # A catalog entry can say post is supported. Media, replies, groups, and
  # schedules stay unavailable in M3-1 even when the grant lists media.
  # The catalog is not checked again at send time.
  def self.build(delegation)
    account = delegation.posting_account
    post_ready = Array(delegation.scopes).map(&:to_s).include?('post')
    capabilities = PostingIdentity::CAPABILITIES.index_with { PostingIdentity::CAPABILITY_UNAVAILABLE }
    capabilities['post'] = PostingIdentity::CAPABILITY_SUPPORTED if post_ready

    PostingIdentity::Record.new(
      id: PostingIdentity.delegated_id(account),
      kind: PostingIdentity::DELEGATED_KIND,
      provider: PostingIdentity::LOCAL_PROVIDER,
      account: account,
      authorization: post_ready ? PostingIdentity::AUTHORIZATION_READY : PostingIdentity::AUTHORIZATION_UNAVAILABLE,
      capabilities: capabilities,
      delegation: {
        state: 'active',
        scopes: Array(delegation.scopes),
        expires_at: delegation.expires_at,
        approved_at: delegation.approved_at,
      }
    )
  end
end
