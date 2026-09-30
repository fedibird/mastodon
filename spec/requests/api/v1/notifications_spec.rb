# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Notifications' do
  let(:user)    { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:scopes)  { 'read:notifications' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' } }
  let(:params)  { {} }

  describe 'GET /api/v1/notifications/unread_count' do
    subject do
      get '/api/v1/notifications/unread_count', headers: headers, params: params
    end

    context 'with notifications' do
      let(:follower) { Fabricate(:account) }

      before do
        first_status = PostStatusService.new.call(user.account, text: 'Test')
        ReblogService.new.call(Fabricate(:account), first_status)
        PostStatusService.new.call(Fabricate(:account), text: 'Hello @alice')
        FavouriteService.new.call(Fabricate(:account), first_status)
        FavouriteService.new.call(Fabricate(:account), first_status)
        FollowService.new.call(follower, user.account)
      end

      it 'returns the unread count', :aggregate_failures do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json.keys).to eq %i(count)
        expect(body_as_json[:count]).to eq 5
      end

      context 'with a read marker' do
        let!(:marker) do
          notifications = user.account.notifications.browserable.order(id: :asc).to_a
          user.markers.create!(timeline: 'notifications', last_read_id: notifications[2].id)
        end

        it 'counts only notifications newer than the marker and leaves the marker unchanged', :aggregate_failures do
          expect { subject }.not_to(change { marker.reload.attributes.slice('last_read_id', 'updated_at', 'lock_version') })

          expect(response).to have_http_status(200)
          expect(body_as_json).to eq(count: 2)
        end
      end

      context 'with exclude_types' do
        let(:params) { { exclude_types: %w(mention) } }

        it 'omits the excluded type' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 4
        end
      end

      context 'with types' do
        let(:params) { { types: %w(mention) } }

        it 'counts only the requested type' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 1
        end
      end

      context 'with account_id' do
        let(:params) { { account_id: follower.id } }

        it 'counts only notifications from that account' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 1
        end
      end

      context 'with limit=2' do
        let(:params) { { limit: 2 } }

        it 'caps the count at the requested limit' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 2
        end
      end

      context 'with a negative limit' do
        let(:params) { { limit: -2 } }

        it 'uses the absolute value' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 2
        end
      end

      context 'when unread notifications exceed the default cap' do
        before do
          stub_const('Api::V1::NotificationsController::DEFAULT_NOTIFICATIONS_COUNT_LIMIT', 2)
        end

        it 'caps the count at the default limit' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 2
        end
      end

      context 'when the requested limit exceeds the maximum' do
        before do
          stub_const('Api::V1::NotificationsController::MAX_NOTIFICATIONS_COUNT_LIMIT', 2)
        end

        let(:params) { { limit: 9999 } }

        it 'caps the count at the maximum' do
          subject

          expect(response).to have_http_status(200)
          expect(body_as_json[:count]).to eq 2
        end
      end
    end

    context 'with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json[:count]).to eq 0
      end
    end

    context 'with a write:notifications token' do
      let(:scopes) { 'write:notifications' }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'with a write-only token' do
      let(:scopes) { 'write' }

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

    context 'with an application-only token' do
      let(:token) { Fabricate(:accessible_access_token, resource_owner_id: nil, scopes: 'read:notifications') }

      it 'rejects the request' do
        subject

        expect(response).to have_http_status(422)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'This method requires an authenticated user'
      end
    end
  end

  describe 'GET /api/v1/notifications' do
    it 'keeps the one-argument limit cap' do
      stub_const('Api::V1::NotificationsController::DEFAULT_NOTIFICATIONS_LIMIT', 1)
      status = PostStatusService.new.call(user.account, text: 'Test')
      3.times { FavouriteService.new.call(Fabricate(:account), status) }

      get '/api/v1/notifications', headers: headers, params: { limit: 100 }

      expect(response).to have_http_status(200)
      expect(body_as_json.size).to eq 2
    end
  end
end
