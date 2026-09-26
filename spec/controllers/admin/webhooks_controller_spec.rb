# frozen_string_literal: true

require 'rails_helper'

describe Admin::WebhooksController do
  render_views

  let(:user) { user_with_role('Owner') }

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  describe 'GET #index' do
    it 'returns http success' do
      get :index

      expect(response).to have_http_status(:success)
    end
  end

  describe 'GET #new' do
    it 'returns http success and renders view' do
      get :new

      expect(response).to have_http_status(:success)
      expect(response).to render_template(:new)
    end
  end

  describe 'POST #create' do
    it 'creates a new webhook record with valid data' do
      expect do
        post :create, params: { webhook: { url: 'https://example.com/hook', events: ['account.approved'] } }
      end.to change(Webhook, :count).by(1)

      expect(response).to be_redirect
    end

    it 'does not accept a secret from the form' do
      post :create, params: { webhook: { url: 'https://example.com/hook-secret', events: ['account.approved'], secret: 'injected-secret-value' } }

      created = Webhook.find_by!(url: 'https://example.com/hook-secret')
      expect(created.secret).to_not eq 'injected-secret-value'
      expect(created.secret).to match(/\A\h{40}\z/)
    end

    it 'does not create a webhook for an event the actor cannot view' do
      role = UserRole.create!(name: 'Hooks without users', position: 30, permissions_as_keys: ['manage_webhooks'])
      sign_in user_with_role(role), scope: :user

      expect do
        post :create, params: { webhook: { url: 'https://example.com/denied', events: ['account.created'] } }
      end.to_not change(Webhook, :count)

      expect(response).to have_http_status(:success)
      expect(response).to render_template(:new)
    end

    it 'does not create a new webhook record with invalid data' do
      expect do
        post :create, params: { webhook: { url: 'https://example.com/hook', events: [] } }
      end.to_not change(Webhook, :count)

      expect(response).to have_http_status(:success)
      expect(response).to render_template(:new)
    end
  end

  context 'with an existing record' do
    let!(:webhook) { Fabricate(:webhook, events: ['account.created', 'report.created']) }

    describe 'GET #show' do
      it 'returns http success and renders the secret' do
        get :show, params: { id: webhook.id }

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:show)
        expect(response.body).to include(webhook.url)
        expect(response.body).to include(webhook.secret)
      end
    end

    describe 'GET #edit' do
      it 'returns http success and renders view' do
        get :edit, params: { id: webhook.id }

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:edit)
      end
    end

    describe 'PUT #update' do
      it 'updates the record with valid data' do
        put :update, params: { id: webhook.id, webhook: { url: 'https://example.com/new/location' } }

        expect(webhook.reload.url).to match(%r{new/location})
        expect(response).to redirect_to(admin_webhook_path(webhook))
      end

      it 'does not change the secret from params' do
        previous = webhook.secret

        put :update, params: { id: webhook.id, webhook: { secret: 'another-injected-secret-value' } }

        expect(webhook.reload.secret).to eq previous
      end

      it 'does not update the record with invalid data' do
        expect do
          put :update, params: { id: webhook.id, webhook: { url: '' } }
        end.to_not change(webhook, :url)

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:edit)
      end
    end

    describe 'POST #enable and #disable' do
      it 'disables and enables the webhook' do
        post :disable, params: { id: webhook.id }
        expect(webhook.reload.enabled?).to be false

        post :enable, params: { id: webhook.id }
        expect(webhook.reload.enabled?).to be true
      end
    end

    describe 'DELETE #destroy' do
      it 'destroys the record' do
        expect do
          delete :destroy, params: { id: webhook.id }
        end.to change(Webhook, :count).by(-1)

        expect(response).to redirect_to(admin_webhooks_path)
      end
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  describe 'without manage_webhooks' do
    before do
      sign_in user_with_role('Moderator'), scope: :user
    end

    it 'forbids the index' do
      get :index, format: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
