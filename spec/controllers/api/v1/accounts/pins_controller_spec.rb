# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Accounts::PinsController, type: :controller do
  render_views
  let(:john)  { Fabricate(:user, account: Fabricate(:account, username: 'john')) }
  let(:kevin) { Fabricate(:user, account: Fabricate(:account, username: 'kevin')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: john.id, scopes: 'write:accounts') }

  before do
    kevin.account.followers << john.account
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    subject { post :create, params: { account_id: kevin.account.id } }

    it 'returns 200 and marks the relationship endorsed' do
      subject

      expect(response).to have_http_status(200)
      expect(body_as_json[:endorsed]).to eq true
    end

    it 'creates account_pin' do
      expect do
        subject
      end.to change { AccountPin.where(account: john.account, target_account: kevin.account).count }.by(1)
    end

    it 'does not create another pin when the account is already endorsed' do
      subject
      pin = AccountPin.find_by!(account: john.account, target_account: kevin.account)

      expect { post :create, params: { account_id: kevin.account.id } }.to_not change(AccountPin, :count)

      expect(response).to have_http_status(200)
      expect(body_as_json[:endorsed]).to eq true
      expect(AccountPin.find_by!(account: john.account, target_account: kevin.account).id).to eq pin.id
      expect(AccountPin.where(account: john.account, target_account: kevin.account).count).to eq 1
    end
  end

  describe 'DELETE #destroy' do
    subject { delete :destroy, params: { account_id: kevin.account.id } }

    before do
      Fabricate(:account_pin, account: john.account, target_account: kevin.account)
    end

    it 'returns 200 and clears endorsed' do
      subject

      expect(response).to have_http_status(200)
      expect(body_as_json[:endorsed]).to eq false
    end

    it 'destroys account_pin' do
      expect do
        subject
      end.to change { AccountPin.where(account: john.account, target_account: kevin.account).count }.by(-1)
    end
  end
end
