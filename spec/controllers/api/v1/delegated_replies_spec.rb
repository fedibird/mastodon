# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:speaker) { Fabricate(:user, account: Fabricate(:account, username: 'speaker')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses read:statuses') }
  let!(:parent) { Fabricate(:status, account: speaker.account, visibility: :public, text: 'Public hello') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
  end

  def delegate!(scopes: %w(post reply quote), requester: grantee, owner: grantor)
    PostingIdentity::RequestAllowance.permit!(grantor: owner, acct: requester.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: owner.account.username, scopes: scopes, ip: '203.0.113.40')
    PostingIdentity::Approval.call!(approver: owner, token: issued.token)
  end

  def delegated_params(extra = {})
    { visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }.merge(extra)
  end

  describe 'POST #create replies and quotes' do # rubocop:disable Metrics/BlockLength
    it 'refuses a reply or quote that only has post' do
      delegate!(scopes: %w(post))

      expect do
        post :create, params: delegated_params(status: '@speaker hi', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      expect do
        post :create, params: delegated_params(status: 'Quoted', quote_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'does not let reply permission quote, or quote permission reply' do
      delegate!(scopes: %w(post reply))

      expect do
        post :create, params: delegated_params(status: 'Quoted', quote_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: PostingIdentityDelegation.last.id).update_all(scopes: %w(post quote))

      expect do
        post :create, params: delegated_params(status: '@speaker hi', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'publishes a public reply as the granting account' do
      delegation = delegate!(scopes: %w(post reply))

      post :create, params: delegated_params(status: '@speaker hello back', in_reply_to_id: parent.id)

      status = grantor.account.statuses.last
      mention = status.mentions.find_by(account_id: speaker.account.id)

      expect(response).to have_http_status(200)
      expect(status.text).to include('@speaker')
      expect(status.account_id).to eq grantor.account.id
      expect(status.in_reply_to_id).to eq parent.id
      expect(status.in_reply_to_account_id).to eq speaker.account.id
      expect(grantee.account.statuses).to be_empty
      expect(mention).to be_present
      expect(ActivityPub::TagManager.instance.uri_for(status)).to include("/users/#{grantor.account.username}/")
      expect(LocalNotificationWorker).to have_received(:perform_async).with(speaker.account.id, mention.id, 'Mention', 'mention')
      expect(PostingIdentityPost.where(status_id: status.id, grantee_user_id: grantee.id, delegation_id: delegation.id).count).to eq 1
    end

    it 'quotes a public post from quote_id and from QT text through the same grant' do
      delegate!(scopes: %w(post quote))
      url = ActivityPub::TagManager.instance.url_for(parent)

      post :create, params: delegated_params(status: 'Via id', quote_id: parent.id)

      quoted = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(quoted.account_id).to eq grantor.account.id
      expect(quoted.quote_id).to eq parent.id
      expect(quoted.in_reply_to_id).to be_nil

      post :create, params: delegated_params(status: "Via markup QT: [#{url}]")

      marked = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(marked.quote_id).to eq parent.id
      expect(marked.text).not_to include('QT:')
      expect(marked.account_id).to eq grantor.account.id
    end

    it 'rejects mentions in a quote body or content warning, including a reply mixed with a quote' do
      delegate!(scopes: %w(post reply quote))

      expect do
        post :create, params: delegated_params(status: '@stranger quoted', quote_id: parent.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('stranger')

      expect do
        post :create, params: delegated_params(status: 'Quoted', spoiler_text: 'cw @stranger', quote_id: parent.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('stranger')

      expect do
        post :create, params: delegated_params(status: '@speaker both', in_reply_to_id: parent.id, quote_id: parent.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(422)

      post :create, params: delegated_params(status: '@speaker hello back', spoiler_text: 'cw', in_reply_to_id: parent.id)

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.in_reply_to_id).to eq parent.id
      expect(grantor.account.statuses.last.quote_id).to be_nil
    end

    it 'rejects a quote mention in the content warning and accepts the warning without one' do
      delegate!(scopes: %w(post quote))
      url = ActivityPub::TagManager.instance.url_for(parent)

      expect do
        post :create, params: delegated_params(status: 'See the warning', spoiler_text: "QT: [#{url}] @stranger")
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('stranger')

      post :create, params: delegated_params(status: 'See the warning', spoiler_text: "QT: [#{url}]")

      status = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.quote_id).to eq parent.id
      expect(status.account_id).to eq grantor.account.id
      expect(status.mentions).to be_empty
    end

    it 'normalizes a quoted reblog to the original post' do
      delegate!(scopes: %w(post quote))
      booster = Fabricate(:account, username: 'booster')
      boost = Fabricate(:status, account: booster, reblog: parent, visibility: :public)

      post :create, params: delegated_params(status: 'Boosted', quote_id: boost.id)

      status = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.quote_id).to eq parent.id
      expect(status.account_id).to eq grantor.account.id
    end

    it 'requires media permission for an image reply and keeps the granting account as owner' do
      delegation = delegate!(scopes: %w(post reply))

      expect do
        post :create, params: delegated_params(status: '@speaker pic', in_reply_to_id: parent.id, media_ids: ['1'])
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post reply media))
      media = Fabricate(:media_attachment, account: grantor.account, type: :image)
      PostingIdentityMedia.create!(
        grantee_user: grantee,
        delegation: delegation,
        posting_account: grantor.account,
        media_attachment: media
      )

      post :create, params: delegated_params(status: '@speaker pic', in_reply_to_id: parent.id, media_ids: [media.id])

      status = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.media_attachments.map(&:id)).to eq [media.id]
      expect(status.account_id).to eq grantor.account.id
      expect(status.in_reply_to_id).to eq parent.id
    end

    it 'hides a post the operator cannot see and does not reveal its text' do
      delegate!(scopes: %w(post reply quote))
      secret = Fabricate(:status, account: speaker.account, visibility: :private, text: 'secret-followers-only-body')
      Fabricate(:follow, account: grantor.account, target_account: speaker.account)

      expect do
        post :create, params: delegated_params(status: '@speaker hidden', in_reply_to_id: secret.id, visibility: 'private')
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(404)
      expect(response.body).not_to include('secret-followers-only-body')

      expect do
        post :create, params: delegated_params(status: 'Hidden quote', quote_id: secret.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(404)
      expect(response.body).not_to include('secret-followers-only-body')

      get :show, params: { id: secret.id }

      expect(response).not_to have_http_status(200)
      expect(response.body).not_to include('secret-followers-only-body')
    end

    it 'refuses a post the granting account cannot see, reply to, or quote' do
      delegate!(scopes: %w(post reply quote))
      secret = Fabricate(:status, account: speaker.account, visibility: :private, text: 'author-only-followers')
      Fabricate(:follow, account: grantee.account, target_account: speaker.account)

      expect do
        post :create, params: delegated_params(status: '@speaker no', in_reply_to_id: secret.id, visibility: 'private')
      end.not_to change(Status, :count)

      expect(response).to have_http_status(404)
      expect(response.body).not_to include('author-only-followers')
    end

    it 'follows block, mute, and followers-only rules for the granting account' do
      delegate!(scopes: %w(post reply quote))
      Fabricate(:follow, account: grantee.account, target_account: speaker.account)
      Fabricate(:follow, account: grantor.account, target_account: speaker.account)
      secret = Fabricate(:status, account: speaker.account, visibility: :private, text: 'followers hello')

      post :create, params: delegated_params(status: '@speaker private reply', in_reply_to_id: secret.id, visibility: 'private')

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.visibility).to eq 'private'
      expect(grantor.account.statuses.last.in_reply_to_id).to eq secret.id

      post :create, params: delegated_params(status: '@speaker too open', in_reply_to_id: secret.id, visibility: 'public')

      expect(response).to have_http_status(422)

      expect do
        post :create, params: delegated_params(status: 'No private quote', quote_id: secret.id)
      end.not_to(change { grantor.account.statuses.where(quote_id: secret.id).count })

      expect(response).to have_http_status(422)

      Fabricate(:block, account: grantor.account, target_account: speaker.account)

      expect do
        post :create, params: delegated_params(status: '@speaker blocked', in_reply_to_id: parent.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(404)

      Block.where(account: grantor.account, target_account: speaker.account).delete_all
      Fabricate(:mute, account: grantor.account, target_account: speaker.account)

      expect do
        post :create, params: delegated_params(status: '@speaker muted', in_reply_to_id: parent.id)
      end.not_to(change { grantor.account.statuses.count })

      expect(response).to have_http_status(404)
    end

    it 'refuses a deleted or expired target and an extra mention' do
      delegate!(scopes: %w(post reply))
      parent.discard

      expect do
        post :create, params: delegated_params(status: '@speaker gone', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(404)

      parent.update_columns(deleted_at: nil)
      parent.update!(expired_at: 1.hour.ago)

      expect do
        post :create, params: delegated_params(status: '@speaker old', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(404)

      parent.update!(expired_at: nil)

      expect do
        post :create, params: delegated_params(status: '@speaker @stranger hello', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('stranger')
    end

    it 'refuses a group destination and a revoked grant without creating another reply' do
      delegation = delegate!(scopes: %w(post reply quote))
      club = Fabricate(:account, username: 'club', actor_type: 'Group')
      group_status = Fabricate(:status, account: club, visibility: :public, text: 'group hello')

      expect do
        post :create, params: delegated_params(status: '@club hi', in_reply_to_id: group_status.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      expect do
        post :create, params: delegated_params(status: 'Audience', audience_account_id: club.id, quote_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      request.headers['Idempotency-Key'] = 'reply-once'
      post :create, params: delegated_params(status: '@speaker once', in_reply_to_id: parent.id)
      first = grantor.account.statuses.last

      expect do
        post :create, params: delegated_params(status: '@speaker once', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(grantor.account.statuses.last.id).to eq first.id
      expect(PostingIdentityPost.where(status_id: first.id).count).to eq 1

      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)

      expect do
        post :create, params: delegated_params(status: '@speaker later', in_reply_to_id: parent.id)
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
      expect(PostingIdentityPost.count).to eq 1
    end

    it 'keeps an ordinary reply from the signed-in account' do
      delegate!(scopes: %w(post reply))

      post :create, params: { status: '@speaker myself', in_reply_to_id: parent.id, visibility: 'public' }

      status = grantee.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.account_id).to eq grantee.account.id
      expect(status.in_reply_to_id).to eq parent.id
      expect(grantor.account.statuses).to be_empty
      expect(PostingIdentityPost.count).to eq 0
    end
  end
end

RSpec.describe Api::V1::Fedibird::PostingIdentitiesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'checker')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'source')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses') }
  let(:parent) { Fabricate(:status, account: grantor.account, visibility: :public, text: 'visible-target') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def delegate!(scopes:)
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: scopes, ip: '203.0.113.41')
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  it 'confirms a delegated reply without returning the post' do
    delegate!(scopes: %w(post reply))

    post :interaction, params: {
      posting_identity_id: "delegated:#{grantor.account.id}",
      in_reply_to_id: parent.id,
      visibility: 'public',
      status: '@source hello',
    }

    expect(response).to have_http_status(204)
    expect(response.body).to eq ''
    expect(response.body).not_to include('visible-target')
  end

  it 'uses the same mention decision for a content warning as posting does' do
    delegate!(scopes: %w(post quote))
    parent = Fabricate(:status, account: grantor.account, visibility: :public, text: 'visible-target')
    url = ActivityPub::TagManager.instance.url_for(parent)

    post :interaction, params: {
      posting_identity_id: "delegated:#{grantor.account.id}",
      status: 'See the warning',
      spoiler_text: "QT: [#{url}] @stranger",
      visibility: 'public',
    }

    expect(response).to have_http_status(422)
    expect(response.body).not_to include('stranger')
    expect(response.body).not_to include('visible-target')

    post :interaction, params: {
      posting_identity_id: "delegated:#{grantor.account.id}",
      status: 'See the warning',
      spoiler_text: "QT: [#{url}]",
      visibility: 'public',
    }

    expect(response).to have_http_status(204)
    expect(response.body).to eq ''
    expect(grantor.account.statuses.where(quote_id: parent.id)).to be_empty
  end

  it 'does not reveal a post the operator cannot see' do
    delegate!(scopes: %w(post reply quote))
    secret = Fabricate(:status, account: grantor.account, visibility: :private, text: 'hidden-target-body')

    post :interaction, params: {
      posting_identity_id: "delegated:#{grantor.account.id}",
      quote_id: secret.id,
      visibility: 'public',
      status: 'quote',
    }

    expect(response).to have_http_status(404)
    expect(response.body).not_to include('hidden-target-body')
    expect(Status.where(account: grantee.account)).to be_empty
  end
end
