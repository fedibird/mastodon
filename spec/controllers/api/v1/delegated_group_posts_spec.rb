# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses read:statuses') }
  let(:group_user) { Fabricate(:user, account: Fabricate(:account, username: 'localsquad', actor_type: 'Group')) }
  let(:group) { group_user.account }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
  end

  def delegate!(scopes: %w(post group), requester: grantee, owner: grantor)
    PostingIdentity::RequestAllowance.permit!(grantor: owner, acct: requester.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: owner.account.username, scopes: scopes, ip: '203.0.113.40')
    PostingIdentity::Approval.call!(approver: owner, token: issued.token)
  end

  def group_params(extra = {})
    {
      status: '@localsquad hello group',
      visibility: 'public',
      posting_identity_id: "delegated:#{grantor.account.id}",
      posting_context_account_id: group.id,
      posting_context_key: "builtin:fedibird-group:#{group.id}",
      posting_context_revision: 1,
    }.merge(extra)
  end

  def follow_group!(account = grantor.account)
    account.follow!(group)
  end

  describe 'POST #create local group posts' do # rubocop:disable Metrics/BlockLength
    it 'refuses a post-only grant and does not add group to an existing grant' do
      delegation = delegate!(scopes: %w(post))
      follow_group!

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
      expect(delegation.reload.scopes).to eq %w(post)
      expect(PostingIdentity::Delegated.build(delegation).capabilities['group']).to eq 'unavailable'
    end

    it 'publishes a public local group post as the granting account' do
      delegation = delegate!
      follow_group!
      expect(grantee.account.following?(group)).to be false

      post :create, params: group_params

      status = grantor.account.statuses.where(reblog_of_id: nil).last
      boost = Status.find_by(reblog_of_id: status.id, account_id: group.id)

      expect(response).to have_http_status(200)
      expect(status.account_id).to eq grantor.account.id
      expect(status.visibility).to eq 'public'
      expect(status.in_reply_to_id).to be_nil
      expect(status.quote_id).to be_nil
      expect(status.audience_account_id).to be_nil
      expect(status.mentions.map(&:account_id)).to eq [group.id]
      expect(grantee.account.statuses).to be_empty
      expect(boost).to be_present
      expect(boost.visibility).to eq 'public'
      expect(ActivityPub::TagManager.instance.uri_for(status)).to include("/users/#{grantor.account.username}/")
      expect(ActivityPub::TagManager.instance.uri_for(status.account)).to include("/users/#{grantor.account.username}")
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(PostingIdentityPost.where(status_id: status.id, grantee_user_id: grantee.id, delegation_id: delegation.id, posting_account_id: grantor.account.id).count).to eq 1

      post :create, params: group_params(status: '@localsquad hello @author', spoiler_text: '@author')

      mentioned = grantor.account.statuses.where(reblog_of_id: nil).find_by!(text: '@localsquad hello @author')

      expect(response).to have_http_status(200)
      expect(mentioned.mentions.map(&:account_id)).to contain_exactly(group.id, grantor.account.id)
    end

    it 'allows an unlisted group post and refuses tighter visibilities' do
      delegate!
      follow_group!

      post :create, params: group_params(status: '@localsquad quiet', visibility: 'unlisted')

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.visibility).to eq 'unlisted'

      %w(private direct personal mutual limited).each do |visibility|
        expect do
          post :create, params: group_params(visibility: visibility)
        end.not_to change(Status, :count)

        expect(response).to have_http_status(422)
      end
    end

    it 'does not treat the operator follow as the granting account follow' do
      delegate!
      grantee.account.follow!(group)

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
      expect(grantor.account.following?(group)).to be false
    end

    it 'refuses a missing mention, another group, and a content-warning mention' do
      delegate!
      follow_group!
      other = Fabricate(:account, username: 'othergroup', actor_type: 'Group')

      expect do
        post :create, params: group_params(status: 'hello group')
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      expect do
        post :create, params: group_params(status: '@othergroup hello')
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
      expect(other.mentions).to be_empty

      expect do
        post :create, params: group_params(spoiler_text: 'cw @stranger')
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('stranger')
    end

    it 'refuses a remote group, a group reply, and a group quote' do
      delegate!(scopes: %w(post group reply quote))
      follow_group!
      remote = Fabricate(:account, username: 'remote', domain: 'example.com', actor_type: 'Group', uri: 'https://example.com/users/remote', inbox_url: 'https://example.com/inbox')
      parent = Fabricate(:status, account: group, visibility: :public, text: 'Inside')

      expect do
        post :create, params: group_params(posting_context_account_id: remote.id, posting_context_key: "builtin:fedibird-group:#{remote.id}")
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      expect do
        post :create, params: group_params(in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      expect do
        post :create, params: group_params(quote_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
    end

    it 'requires media scope and the granting account audit for a still image' do
      delegation = delegate!(scopes: %w(post group))
      follow_group!
      owned = Fabricate(:media_attachment, account: grantor.account, status: nil)
      PostingIdentityMedia.create!(grantee_user: grantee, delegation: delegation, posting_account: grantor.account, media_attachment: owned)

      expect do
        post :create, params: group_params(media_ids: [owned.id])
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post group media))
      operator_media = Fabricate(:media_attachment, account: grantee.account, status: nil)

      expect do
        post :create, params: group_params(media_ids: [operator_media.id])
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      other = delegate!(scopes: %w(post group media), requester: user_with_role('Owner', account: Fabricate(:account, username: 'other_poster')))
      foreign = Fabricate(:media_attachment, account: grantor.account, status: nil)
      PostingIdentityMedia.create!(grantee_user: other.grantee_user, delegation: other, posting_account: grantor.account, media_attachment: foreign)

      expect do
        post :create, params: group_params(media_ids: [foreign.id])
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      post :create, params: group_params(media_ids: [owned.id])

      status = grantor.account.statuses.where(reblog_of_id: nil).last

      expect(response).to have_http_status(200)
      expect(status.media_attachments.map(&:id)).to eq [owned.id]
      expect(status.account_id).to eq grantor.account.id
    end

    it 'refuses a revoked grant, an expired grant, and a dropped follow' do
      delegation = delegate!
      follow_group!
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation)

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      delegation = delegate!
      delegation.update_columns(expires_at: 1.minute.ago)

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      delegate!
      follow_group!
      UnfollowService.new.call(grantor.account, group)

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
    end

    it 'uses the group conditions at send time' do
      delegate!
      follow_group!
      group.update!(actor_type: 'Person')

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      group.update!(actor_type: 'Group', username: 'renamed')
      follow_group!

      expect do
        post :create, params: group_params
      end.not_to change(Status, :count)

      post :create, params: group_params(status: '@renamed hello group', posting_context_key: "builtin:fedibird-group:#{group.id}")

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.text).to include('@renamed')
    end

    it 'does not create a second group post when the idempotency key is repeated' do
      delegation = delegate!
      follow_group!
      request.headers['Idempotency-Key'] = 'group-once'

      post :create, params: group_params
      first = grantor.account.statuses.where(reblog_of_id: nil).last

      expect do
        post :create, params: group_params
      end.not_to change(grantor.account.statuses.where(reblog_of_id: nil), :count)

      expect(grantor.account.statuses.where(reblog_of_id: nil).last.id).to eq first.id
      expect(PostingIdentityPost.where(delegation_id: delegation.id).count).to eq 1
    end

    it 'keeps an ordinary group post and an ordinary delegated post' do
      delegate!(scopes: %w(post reply quote))
      grantee.account.follow!(group)

      post :create, params: { status: '@localsquad from me', visibility: 'public' }

      own = grantee.account.statuses.where(reblog_of_id: nil).last

      expect(response).to have_http_status(200)
      expect(own.account_id).to eq grantee.account.id
      expect(Status.where(reblog_of_id: own.id, account_id: group.id)).to exist

      post :create, params: { status: 'Plain delegated', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.text).to eq 'Plain delegated'
      expect(grantor.account.statuses.last.mentions).to be_empty

      parent = Fabricate(:status, account: grantee.account, visibility: :public, text: 'Parent')
      PostingIdentityDelegation.last.update!(scopes: %w(post reply))

      post :create, params: { status: '@poster reply', visibility: 'public', in_reply_to_id: parent.id, posting_identity_id: "delegated:#{grantor.account.id}" }

      reply = grantor.account.statuses.find_by!(text: '@poster reply')

      expect(response).to have_http_status(200)
      expect(reply.in_reply_to_id).to eq parent.id
    end
  end
end
