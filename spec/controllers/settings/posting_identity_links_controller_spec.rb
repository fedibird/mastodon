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
      expect(Nokogiri::HTML(response.body).at('h2').text).to include('Linked accounts')
      expect(response.body).to include('People who can use your account')
      expect(response.body).to include('Accounts allowed to request a link')
      expect(response.body).to include('Allow links from other accounts')
      expect(response.body).to include('Accept link requests')
      expect(response.body).to include('hidden_allowance')
      expect(response.body).not_to include('Request a link')
      expect(response.body).to include('Only an administrator can request a new link')
      expect(Nokogiri::HTML(response.body).at("form[action='#{settings_posting_identity_links_path}']")).to be_nil

      sign_out :user
      sign_in Fabricate(:user), scope: :user
      get :index

      expect(response.body).not_to include('hidden_allowance')
      expect(response.body).not_to include('Request a link')
      expect(response.body).to include('Accept link requests')
    end

    it 'titles the page in Japanese and gives an administrator the request form' do
      sign_in user_with_role('Owner', locale: 'ja'), scope: :user

      get :index

      document = Nokogiri::HTML(response.body)
      form = document.at("form.simple_form[action='#{settings_posting_identity_links_path}']")

      expect(document.at('h2').text).to include('連携アカウント')
      expect(form['method']).to eq('post')
      expect(form['data-remote']).to be_nil
      expect(form.at('label[for="posting_identity_request_acct"]')).to be_present
      expect(form.at('input#posting_identity_request_acct.string')).to be_present
      expect(form.at('.fields-group .input.with_label')).to be_present
      expect(form.at('.input.boolean label.checkbox input#posting_identity_request_scope_media')).to be_present
      expect(form.at('label[for="posting_identity_request_scope_media"]')).to be_present
      expect(form.at('.actions button.button[type="submit"]').text).to include('連携を申請する')
      expect(response.body).not_to include('Misskey')
      expect(response.body).not_to include('Bluesky')
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

  describe 'GET #index forms' do
    around do |example|
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    it 'gives each action its own standard form, method, and CSRF token' do
      PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
      issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.94')
      delegation = PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
      open_request = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.95')
      sign_in grantee, scope: :user

      get :index

      document = Nokogiri::HTML(response.body)
      request_form = document.at("form.simple_form[action='#{settings_posting_identity_links_path}']")
      unlink = document.at("form.simple_form[action='#{unlink_settings_posting_identity_grant_path(delegation)}']")
      cancel = document.at("form.simple_form[action='#{cancel_settings_posting_identity_link_path(open_request.request)}']")

      expect(request_form['method']).to eq('post')
      expect(request_form.at('input[name="authenticity_token"]')['value']).to be_present
      expect(request_form.at('.actions button.button.negative')).to be_nil
      [unlink, cancel].each do |form|
        expect(form['method']).to eq('post')
        expect(form['data-remote']).to be_nil
        expect(form.at('input[name="authenticity_token"]')['value']).to be_present
        expect(form.at('.actions button.button.negative[type="submit"]')).to be_present
      end

      sign_out :user
      sign_in grantor, scope: :user
      get :index

      document = Nokogiri::HTML(response.body)
      allowance = document.at("form.simple_form[action='#{settings_posting_identity_request_allowances_path}']")
      revoke_allowance = document.at("form.simple_form[action='#{revoke_settings_posting_identity_request_allowance_path(PostingIdentityRequestAllowance.last)}']")
      revoke_grant = document.at("form.simple_form[action='#{revoke_settings_posting_identity_grant_path(delegation)}']")

      expect(allowance['method']).to eq('post')
      expect(allowance.at('label[for="posting_identity_allowance_acct"]')).to be_present
      expect(allowance.at('.input.boolean.with_label label.checkbox input#posting_identity_allowance_scope_media')).to be_present
      expect(allowance.at('.actions button.button[type="submit"]')).to be_present
      expect(allowance.at('input[name="authenticity_token"]')['value']).to be_present
      expect(allowance.at('button.negative')).to be_nil
      [revoke_allowance, revoke_grant].each do |form|
        expect(form['method']).to eq('post')
        expect(form.at('input[name="authenticity_token"]')['value']).to be_present
        expect(form.at('.actions button.button.negative[type="submit"]')).to be_present
        expect(form.at('.actions button.button:not(.negative)')).to be_nil
      end
    end
  end
end
