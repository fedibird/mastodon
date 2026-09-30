# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Domain Block Previews' do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'write:blocks' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' } }
  let(:domain)  { 'example.com' }

  describe 'GET /api/v1/domain_blocks/preview' do
    subject do
      get '/api/v1/domain_blocks/preview', params: { domain: domain }, headers: headers
    end

    context 'with relationships on the domain' do
      before do
        %w(alice bob).each do |username|
          user.account.follow!(remote_account(username, 'example.com'))
        end
        user.account.follow!(remote_account('carol', 'example.net'))
        remote_account('dave', 'example.com').follow!(user.account)
        remote_account('erin', 'example.net').follow!(user.account)
      end

      it 'returns following and follower counts for the domain', :aggregate_failures do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json.keys).to eq %i(following_count followers_count)
        expect(body_as_json).to eq(following_count: 2, followers_count: 1)
      end

      context 'when the domain is uppercase' do
        let(:domain) { 'EXAMPLE.COM' }

        it 'normalizes the domain before counting' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json).to eq(following_count: 2, followers_count: 1)
        end
      end

      context 'when the domain has a trailing slash' do
        let(:domain) { 'example.com/' }

        it 'normalizes the domain before counting' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json).to eq(following_count: 2, followers_count: 1)
        end
      end

      context 'when domain blocks are disabled for the user' do
        before do
          user.settings.disable_domain_block = true
        end

        it 'still returns the preview' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json).to eq(following_count: 2, followers_count: 1)
        end
      end
    end

    context 'when the domain has no relationships' do
      let(:domain) { 'unused.example' }

      it 'returns zero counts', :aggregate_failures do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json.keys).to eq %i(following_count followers_count)
        expect(body_as_json).to eq(following_count: 0, followers_count: 0)
      end
    end

    context 'with the write scope' do
      let(:scopes) { 'write' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    context 'with the follow scope' do
      let(:scopes) { 'follow' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    context 'with the read:blocks scope' do
      let(:scopes) { 'read:blocks' }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
      end
    end

    context 'with the profile scope' do
      let(:scopes) { 'profile' }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
      end
    end

    context 'without a token' do
      let(:headers) { { 'Accept' => 'application/json' } }

      it 'returns http unauthorized' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type).to start_with('application/json')
      end
    end
  end

  def remote_account(username, domain)
    Fabricate(
      :account,
      username: username,
      domain: domain,
      protocol: :activitypub,
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    )
  end
end
