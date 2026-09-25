# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Oauth::AuthorizationsController, type: :controller do
  render_views

  before { stub_webpacker_manifest }

  let(:app) { Doorkeeper::Application.create!(name: 'test', redirect_uri: 'http://localhost/', scopes: 'read') }

  describe 'GET #new' do
    subject do
      get :new, params: { client_id: app.uid, response_type: 'code', redirect_uri: 'http://localhost/', scope: 'read' }
    end

    shared_examples 'stores location for user' do
      it 'stores location for user' do
        subject
        expect(controller.stored_location_for(:user)).to eq "/oauth/authorize?client_id=#{app.uid}&redirect_uri=http%3A%2F%2Flocalhost%2F&response_type=code&scope=read"
      end
    end

    context 'when signed in' do
      let!(:user) { Fabricate(:user) }

      before do
        sign_in user, scope: :user
      end

      it 'returns http success' do
        subject
        expect(response).to have_http_status(200)
      end

      it 'gives options to authorize and deny' do
        subject
        expect(response.body).to include('Authorize', 'Deny', 'Review permissions')
      end

      it 'does not store the prompt in a shared cache' do
        subject
        expect(response.headers['Cache-Control']).to include('private', 'no-store')
      end

      it 'warns that the named application is third-party' do
        subject
        expect(response.body).to include('test', 'would like permission to access your account', 'If you do not trust it')
      end

      it 'groups read and write account scopes' do
        app.update!(scopes: 'read write read:accounts write:accounts')
        get :new, params: { client_id: app.uid, response_type: 'code', redirect_uri: 'http://localhost/', scope: 'read:accounts write:accounts' }

        expect(response).to have_http_status(200)
        expect(response.body).to include('Accounts', 'Read and write access')
        expect(response.body).not_to include('see accounts information', 'modify your profile')
      end

      it 'keeps authorize and deny forms with the OAuth hidden fields' do
        subject
        expect(response.body).to include('method="post"', 'name="_method" value="delete"')
        %w(client_id redirect_uri state response_type scope).each do |field|
          expect(response.body).to include(%(name="#{field}"))
        end
      end

      it 'renders the Japanese permission review' do
        user.update!(locale: 'ja')
        app.update!(scopes: 'read write read:accounts write:accounts')
        get :new, params: { client_id: app.uid, response_type: 'code', redirect_uri: 'http://localhost/', scope: 'read:accounts write:accounts' }

        expect(response.body).to include('アクセス許可を確認', 'アカウント', '読み取りおよび書き込みアクセス')
      end

      include_examples 'stores location for user'

      context 'when app is already authorized' do
        before do
          Doorkeeper::AccessToken.find_or_create_for(
            application: app,
            resource_owner: user.id,
            scopes: app.scopes,
            expires_in: Doorkeeper.configuration.access_token_expires_in,
            use_refresh_token: Doorkeeper.configuration.refresh_token_enabled?
          )
        end

        it 'redirects to callback' do
          subject
          expect(response).to redirect_to(/\A#{app.redirect_uri}/)
        end

        it 'does not redirect to callback with force_login=true' do
          get :new, params: { client_id: app.uid, response_type: 'code', redirect_uri: 'http://localhost/', scope: 'read', force_login: 'true' }
          expect(response.body).to match(/Authorize/)
        end
      end
    end

    context 'when not signed in' do
      it 'redirects' do
        subject
        expect(response).to redirect_to '/auth/sign_in'
      end

      include_examples 'stores location for user'
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
