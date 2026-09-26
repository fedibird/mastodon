# frozen_string_literal: true

require 'rails_helper'

describe Admin::Webhooks::SecretsController do
  let(:user) { user_with_role('Owner') }
  let!(:webhook) { Fabricate(:webhook) }

  before do
    sign_in user, scope: :user
  end

  describe 'POST #rotate' do
    it 'rotates the secret' do
      previous = webhook.secret

      post :rotate, params: { webhook_id: webhook.id }

      expect(webhook.reload.secret).to_not eq previous
      expect(response).to redirect_to(admin_webhook_path(webhook))
    end

    it 'forbids a user without manage_webhooks' do
      sign_in user_with_role('Moderator'), scope: :user
      previous = webhook.secret

      post :rotate, params: { webhook_id: webhook.id }, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(webhook.reload.secret).to eq previous
    end
  end
end