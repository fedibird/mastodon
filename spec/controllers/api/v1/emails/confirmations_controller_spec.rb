# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Emails::ConfirmationsController, type: :controller do
  render_views

  let(:application) { Fabricate(:application) }
  let(:user) { Fabricate(:user, confirmed_at: confirmed_at, unconfirmed_email: unconfirmed_email, created_by_application_id: application.id) }
  let(:confirmed_at) { Time.zone.now }
  let(:unconfirmed_email) { nil }
  let(:token) { Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:accounts' }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow_any_instance_of(User).to receive(:resend_confirmation_instructions)
  end

  describe 'GET #check' do
    it 'returns true for a confirmed user' do
      get :check

      expect(response).to have_http_status(200)
      expect(body_as_json).to be true
    end

    it 'returns false for an unconfirmed user' do
      user.update_columns(confirmed_at: nil)

      get :check

      expect(response).to have_http_status(200)
      expect(body_as_json).to be false
    end

    it 'returns true while a confirmed user is reconfirming a new address' do
      user.update_columns(unconfirmed_email: 'next@example.com')

      get :check

      expect(response).to have_http_status(200)
      expect(body_as_json).to be true
    end

    it 'accepts the read scope' do
      token.update!(scopes: 'read')

      get :check

      expect(response).to have_http_status(200)
    end

    it 'accepts read:accounts' do
      token.update!(scopes: 'read:accounts')

      get :check

      expect(response).to have_http_status(200)
    end

    it 'rejects a token without read or read:accounts' do
      token.update!(scopes: 'write:statuses')

      get :check

      expect(response).to have_http_status(403)
    end

    it 'requires an authenticated user' do
      allow(controller).to receive(:doorkeeper_token).and_return(nil)

      get :check

      expect(response).to have_http_status(401)
      expect(body_as_json[:error]).to eq 'This method requires an authenticated user'
    end
  end

  describe 'POST #create' do
    let(:scopes) { 'write:accounts' }

    it 'keeps the signup application constraint' do
      other = Fabricate(:application)
      token.update!(application_id: other.id)

      post :create, params: { email: 'next@example.com' }

      expect(response).to have_http_status(403)
      expect(body_as_json[:error]).to eq 'This method is only available to the application the user originally signed-up with'
    end

    it 'allows a confirmed user who has a pending reconfirmation address' do
      user.update_columns(unconfirmed_email: 'next@example.com')

      post :create

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
    end

    it 'rejects a confirmed user with no pending address' do
      post :create

      expect(response).to have_http_status(403)
      expect(body_as_json[:error]).to eq 'This method is only available while the e-mail is awaiting confirmation'
    end

    it 'allows an unconfirmed user' do
      user.update_columns(confirmed_at: nil)

      post :create

      expect(response).to have_http_status(200)
    end
  end
end
