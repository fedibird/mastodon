# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Deleting profile images' do
  let(:user) { Fabricate(:user) }
  let(:account) { user.account }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'write:accounts' }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      subject

      expect(response).to have_http_status(403)
    end
  end

  def attach_avatar_and_header!
    account.update!(
      avatar: fixture_file_upload('avatar.gif', 'image/gif'),
      header: fixture_file_upload('attachment.jpg', 'image/jpeg')
    )
  end

  describe 'DELETE /api/v1/profile' do
    before do
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
    end

    context 'when deleting an avatar' do
      subject { delete '/api/v1/profile/avatar', headers: headers }

      before { attach_avatar_and_header! }

      it_behaves_like 'forbidden for wrong scope', 'read'

      it 'returns http success and a credential account' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json[:id]).to eq(account.id.to_s)
        expect(body_as_json).to include(:source)
      end

      it 'deletes the avatar' do
        subject
        account.reload

        expect(account.avatar).to_not exist
      end

      it 'does not delete the header' do
        subject
        account.reload

        expect(account.header).to exist
      end

      it 'queues up an account update distribution' do
        subject

        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(account.id).once
      end
    end

    context 'when deleting a header' do
      subject { delete '/api/v1/profile/header', headers: headers }

      before { attach_avatar_and_header! }

      it 'returns http success and a credential account' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json[:id]).to eq(account.id.to_s)
        expect(body_as_json).to include(:source)
      end

      it 'does not delete the avatar' do
        subject
        account.reload

        expect(account.avatar).to exist
      end

      it 'deletes the header' do
        subject
        account.reload

        expect(account.header).to_not exist
      end

      it 'queues up an account update distribution' do
        subject

        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(account.id).once
      end
    end

    context 'when provided picture value is invalid' do
      subject { delete '/api/v1/profile/invalid', headers: headers }

      before { attach_avatar_and_header! }

      it 'returns http not found' do
        subject

        expect(response).to have_http_status(404)
      end

      it 'does not change avatar or header' do
        subject
        account.reload

        expect(account.avatar).to exist
        expect(account.header).to exist
      end

      it 'does not queue up an account update distribution' do
        subject

        expect(ActivityPub::UpdateDistributionWorker).to_not have_received(:perform_async)
      end
    end

    context 'when avatar is already missing' do
      before do
        account.update!(header: fixture_file_upload('attachment.jpg', 'image/jpeg'))
      end

      it 'returns http success' do
        delete '/api/v1/profile/avatar', headers: headers

        expect(response).to have_http_status(200)
        expect(account.reload.header).to exist
        expect(account.avatar).to_not exist
      end
    end

    context 'without an oauth token' do
      it 'returns http unauthorized' do
        delete '/api/v1/profile/avatar'

        expect(response).to have_http_status(401)
      end
    end

    it 'routes avatar and header deletes to the split controllers' do
      expect(Rails.application.routes.recognize_path('/api/v1/profile/avatar', method: :delete)).to include(controller: 'api/v1/profile/avatars', action: 'destroy')
      expect(Rails.application.routes.recognize_path('/api/v1/profile/header', method: :delete)).to include(controller: 'api/v1/profile/headers', action: 'destroy')
    end
  end
end
