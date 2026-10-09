# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::PostingIdentityApprovalsController do # rubocop:disable Metrics/BlockLength
  render_views

  before { stub_webpacker_manifest }

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'approver')) }
  let(:issued) do
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post media))
    PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post media), ip: '203.0.113.91')
  end

  before { issued }

  describe 'GET #new' do
    it 'does not approve a code that arrives in the query string' do
      sign_in grantor, scope: :user
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      expect do
        get :new, params: { token: issued.token }
      end.not_to change(PostingIdentityDelegation, :count)

      expect(response).to have_http_status(200)
      expect(issued.request.reload.consumed_at).to be_nil
      expect(response.body).to include('Looking up a code does not approve it')

      document = Nokogiri::HTML(response.body)
      form = document.at("form.simple_form[action='#{preview_settings_posting_identity_approval_path}']")

      expect(document.at('h2').text).to include('Approve a linked account')
      expect(form['method']).to eq('post')
      expect(form['data-remote']).to be_nil
      expect(form.at('input[name="authenticity_token"]')['value']).to be_present
      expect(form.at('label[for="posting_identity_approval_token"]')).to be_present
      expect(form.at('.fields-group .input.with_label input#posting_identity_approval_token')).to be_present
      expect(form.at('.actions button.button[type="submit"]')).to be_present
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end

  describe 'POST #preview' do
    it 'shows the approval and does not create a grant' do
      sign_in grantor, scope: :user
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      allow_any_instance_of(described_class).to receive(:verified_request?).and_return(true)

      expect do
        post :preview, params: { token: issued.token }
      end.not_to change(PostingIdentityDelegation, :count)

      expect(response).to have_http_status(200)
      expect(response.body).to include(grantee.account.username)
      expect(response.body).to include(grantor.account.username)
      expect(response.body).to include('Create new posts')
      expect(response.body).to include('Upload media for new posts')
      expect(response.body).to include('You can revoke this at any time')
      expect(response.body).to include('appear as your account')
      expect(response.body).to include('separate from accepting requests')
      expect(response.body).to include('Sending as this account is not available yet')
      expect(response.body).not_to include(grantee.email)
      expect(issued.request.reload.consumed_at).to be_nil

      document = Nokogiri::HTML(response.body)
      form = document.at("form.simple_form[action='#{settings_posting_identity_approval_path}']")

      expect(form['method']).to eq('post')
      expect(form['data-remote']).to be_nil
      expect(form.at('input[name="token"]')['value']).to eq(issued.token)
      expect(form.at('input[name="authenticity_token"]')['value']).to be_present
      expect(form.at('.actions button.button[type="submit"]').text).to include('Approve this posting permission')
      expect(form.at('button.negative')).to be_nil
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    it 'does not reveal the request to the requester' do
      sign_in grantee, scope: :user

      post :preview, params: { token: issued.token }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include('Confirm before approving')
      expect(PostingIdentityDelegation.count).to eq 0
    end
  end

  describe 'POST #create' do
    it 'approves from the target account' do
      sign_in grantor, scope: :user

      post :create, params: { token: issued.token }

      delegation = PostingIdentityDelegation.last

      expect(response).to redirect_to(settings_posting_identity_links_path)
      expect(delegation.grantor_user).to eq grantor
      expect(delegation.grantee_user).to eq grantee
      expect(issued.request.reload.consumed_at).to be_present
    end
  end
end
