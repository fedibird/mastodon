# frozen_string_literal: true

require 'rails_helper'

describe Oauth::AuthorizedApplicationsController do
  render_views

  before { stub_webpacker_manifest }

  describe 'GET #index' do
    subject do
      get :index
    end

    shared_examples 'stores location for user' do
      it 'stores location for user' do
        subject
        expect(controller.stored_location_for(:user)).to eq "/oauth/authorized_applications"
      end
    end

    context 'when signed in' do
      let(:user) { Fabricate(:user) }

      before do
        sign_in user, scope: :user
      end

      it 'returns http success' do
        subject
        expect(response).to have_http_status(200)
      end

      it 'does not store the page in a shared cache' do
        subject
        expect(response.headers['Cache-Control']).to include('private', 'no-store')
      end

      include_examples 'stores location for user'

      it 'uses the latest token for the current user' do
        application = Fabricate(:application, name: 'Latest App', scopes: 'read:accounts write:accounts')
        older = 3.days.ago
        newer = 1.day.ago
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id, last_used_at: older)
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id, last_used_at: newer)

        subject

        expect(assigns(:last_used_at_by_app)[application.id]).to be_within(1.second).of(newer)
        expect(response.body).to include('Accounts', 'Read and write access', 'Last used on')
      end

      it 'ignores another user token for the same application' do
        application = Fabricate(:application, name: 'Private App', scopes: 'read')
        own_used_at = 2.days.ago
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id, last_used_at: own_used_at)
        Fabricate(:accessible_access_token, application: application, resource_owner_id: Fabricate(:user).id, last_used_at: 1.hour.ago)

        subject

        expect(assigns(:last_used_at_by_app)[application.id]).to be_within(1.second).of(own_used_at)
      end

      it 'shows never used when the token has no last use' do
        application = Fabricate(:application, name: 'Unused App', scopes: 'read')
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id, last_used_at: nil)

        subject

        expect(assigns(:last_used_at_by_app)).not_to have_key(application.id)
        expect(response.body).to include('Never used')
      end

      it 'renders an underscored admin scope' do
        application = Fabricate(:application, name: 'Domain Blocks App', scopes: 'admin:read:domain_blocks')
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id)

        subject

        expect(response).to have_http_status(200)
        expect(response.body).to include('Domain Blocks App')
      end

      it 'shows a revoke link for a normal application' do
        application = Fabricate(:application, name: 'Revocable App', scopes: 'read', website: 'https://app.example')
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id)

        subject

        expect(response.body).to include('Revoke', 'Revocable App')
        expect(response.body).to include('https://app.example')
      end

      it 'hides revoke for a superapp and shows the internal badge' do
        application = Fabricate(:application, name: 'Internal App', scopes: 'read', superapp: true)
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id)

        subject

        expect(response.body).to include('Internal')
        expect(response.body).not_to include('Revoke')
      end

      it 'hides revoke when the account is suspended' do
        user.account.suspend!
        application = Fabricate(:application, name: 'Suspended App', scopes: 'read')
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id)

        subject

        expect(response).to have_http_status(200)
        expect(response.body).not_to include('Revoke')
      end

      it 'renders the Japanese never-used and grouped scope labels' do
        user.update!(locale: 'ja')
        application = Fabricate(:application, name: '日本語アプリ', scopes: 'read:accounts write:accounts')
        Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id)

        subject

        expect(response.body).to include('使用されていない', 'アカウント', '読み取りおよび書き込みアクセス')
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

  describe 'DELETE #destroy' do
    let!(:user) { Fabricate(:user) }
    let!(:application) { Fabricate(:application) }
    let!(:access_token) { Fabricate(:accessible_access_token, application: application, resource_owner_id: user.id) }
    let!(:web_push_subscription) { Fabricate(:web_push_subscription, user: user, access_token: access_token) }
    let(:redis_pipeline_stub) { instance_double(Redis::Namespace, publish: nil) }

    before do
      sign_in user, scope: :user
      allow(redis).to receive(:pipelined).and_yield(redis_pipeline_stub)
      post :destroy, params: { id: application.id }
    end

    it 'revokes access tokens for the application' do
      expect(Doorkeeper::AccessToken.where(application: application).first.revoked_at).to_not be_nil
    end

    it 'removes subscriptions for the application\'s access tokens' do
      expect(Web::PushSubscription.where(user: user).count).to eq 0
    end

    it 'removes the web_push_subscription' do
      expect { web_push_subscription.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'sends a session kill payload to the streaming server' do
      expect(redis_pipeline_stub).to have_received(:publish).with("timeline:access_token:#{access_token.id}", '{"event":"kill"}')
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
