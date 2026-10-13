# frozen_string_literal: true

class Api::V1::Fedibird::Accounts::PostingContextsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }
  before_action :require_user!
  before_action :set_account

  def show
    resolution = delegated_sender
    # The signed-in account remains the viewer for the public context.
    # A delegated request does not receive that account's evidence, and it
    # does not receive the granting account's private profile either.
    payload = PostingContext::DiscoveryService.new.call(@account, viewer: resolution ? nil : current_user.account)
    payload = payload.merge(viewer_evidence: nil, sender_posting: sender_posting(resolution)) if resolution
    render json: payload
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end

  # The route account is the group being discovered. It is never a sender.
  # A delegated identity is resolved from a grant held by the signed-in user.
  def delegated_sender
    identity_id = params[:posting_identity_id].to_s.presence
    return nil if identity_id.nil? || identity_id == PostingIdentity.local_id(current_account)

    resolution = PostingIdentity::SendGuard.resolve!(
      user: current_user,
      posting_identity_id: identity_id,
      purpose: :create
    )
    raise Mastodon::NotPermittedError unless resolution.delegated?
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(
      grantee: current_user,
      delegation: resolution.delegation,
      operation: 'group'
    )

    resolution
  end

  def sender_posting(resolution)
    if PostingContext::Adapters::FedibirdGroup.applicable?(@account)
      return local_sender_posting(resolution)
    end

    remote_sender_posting(resolution)
  end

  def local_sender_posting(resolution)
    decision = PostingIdentity::LocalGroupPost.decision(author: resolution.account, account_id: @account.id)

    {
      identity_id: resolution.identity_id,
      delegation_id: resolution.delegation.id.to_s,
      can_post: decision.can_post,
      following: decision.following,
      permission: {
        status: decision.can_post ? 'allowed' : 'unknown',
        confirmed: decision.can_post,
        source: 'local_follow',
        freshness: 'current',
      },
      delivery: {
        status: decision.group ? 'supported' : 'unsupported',
        adapter: decision.group ? 'fedibird_group' : nil,
        authority: decision.group ? 'server' : nil,
      },
    }
  end

  def remote_sender_posting(resolution)
    decision = PostingIdentity::RemoteGroupPost.decision(author: resolution.account, account_id: @account.id)

    {
      identity_id: resolution.identity_id,
      delegation_id: resolution.delegation.id.to_s,
      can_post: decision.can_post,
      permission: {
        status: decision.permission_status,
        confirmed: decision.permission_confirmed,
        source: decision.permission_source,
        freshness: decision.permission_freshness,
      },
      delivery: {
        status: decision.delivery_status,
        adapter: decision.delivery_adapter,
        authority: decision.delivery_authority,
      },
    }
  end
end
