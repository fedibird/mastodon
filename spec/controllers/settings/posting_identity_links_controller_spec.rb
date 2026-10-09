# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::PostingIdentityLinksController do # rubocop:disable Metrics/BlockLength
  render_views

  before { stub_webpacker_manifest }

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'approver')) }

  describe 'GET #index' do
    it 'shows the sending-account page to a non-administrator without a request form' do
      stranger = Fabricate(:user, account: Fabricate(:account, username: 'hidden_allowance'))
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: stranger.account.username, scopes: %w(post))
      sign_in grantor, scope: :user

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include('People who can post as you')
      expect(response.body).to include('Accounts allowed to request a link')
      expect(response.body).to include('hidden_allowance')
      expect(response.body).not_to include('Create a linking code')

      sign_out :user
      sign_in Fabricate(:user), scope: :user
      get :index

      expect(response.body).not_to include('hidden_allowance')
      expect(response.body).not_to include('Create a linking code')
    end
  end

  describe 'POST #create' do
    it 'forbids a non-administrator' do
      sign_in grantor, scope: :user

      expect do
        post :create, params: { acct: grantee.account.username, scopes: ['post'] }
      end.not_to change(PostingIdentityLinkRequest, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'shows the linking code once for an administrator tester' do
      sign_in grantee, scope: :user
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post media))

      post :create, params: { acct: grantor.account.username, scopes: %w(post media) }

      token = flash[:posting_identity_token]
      stored = PostingIdentityLinkRequest.last

      expect(response).to redirect_to(settings_posting_identity_links_path)
      expect(token).to be_present
      expect(stored.token_digest).to eq PostingIdentityLinkRequest.digest(token)
      expect(stored.scopes).to eq %w(post media)

      get :index

      expect(response.body).to include(token)
      expect(response.body).to include(grantor.account.username)
      expect(response.body).not_to include(grantor.email)
    end
  end

  describe 'GET #index stale requests' do
    it 'separates an earlier generation from the request that can still be approved' do
      Rails.cache.clear
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
      PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.70')
      PostingIdentity::RequestAllowance.revoke!(grantor: grantor, allowance: PostingIdentityRequestAllowance.last)
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
      PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.71')
      sign_in grantee, scope: :user

      get :index

      expect(response.body).to include('Open requests')
      expect(response.body).to include('Requests that can no longer be approved')
      expect(response.body).to include('earlier acceptance')
    end
  end

  describe 'POST #cancel' do
    it 'lets the requester cancel an open request' do
      sign_in grantee, scope: :user
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
      issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.90')

      post :cancel, params: { id: issued.request.id }

      expect(response).to redirect_to(settings_posting_identity_links_path)
      expect(issued.request.reload.canceled_at).to be_present
      expect { PostingIdentity::Approval.call!(approver: grantor, token: issued.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :canceled }
    end
  end
end
