# frozen_string_literal: true

class PostingIdentity::Delegated
  # post is the text capability. media is listed only together with post.
  # Replies, groups, and schedules stay unavailable. The catalog describes
  # the grant at read time and is checked again when a file or status is saved.
  def self.build(delegation)
    account = delegation.posting_account
    scopes = Array(delegation.scopes).map(&:to_s)
    post_ready = scopes.include?('post')
    media_ready = post_ready && scopes.include?('media')
    capabilities = PostingIdentity::CAPABILITIES.index_with { PostingIdentity::CAPABILITY_UNAVAILABLE }
    capabilities['post'] = PostingIdentity::CAPABILITY_SUPPORTED if post_ready
    capabilities['media'] = PostingIdentity::CAPABILITY_SUPPORTED if media_ready

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
