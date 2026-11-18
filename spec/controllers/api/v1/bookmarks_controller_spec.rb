require 'rails_helper'

RSpec.describe Api::V1::BookmarksController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:bookmarks') }

  describe 'GET #index' do
    context 'without token' do
      it 'returns http unauthorized' do
        get :index
        expect(response).to have_http_status :unauthorized
      end
    end

    context 'with token' do
      context 'with only the profile scope' do
        before do
          allow(controller).to receive(:doorkeeper_token) do
            Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'profile')
          end
        end

        it 'returns http forbidden' do
          get :index
          expect(response).to have_http_status :forbidden
        end
      end

      context 'without read scope' do
        before do
          allow(controller).to receive(:doorkeeper_token) do
            Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: '')
          end
        end

        it 'returns http forbidden' do
          get :index
          expect(response).to have_http_status :forbidden
        end
      end

      context 'without valid resource owner' do
        before do
          token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
          user.destroy!

          allow(controller).to receive(:doorkeeper_token) { token }
        end

        it 'returns http unprocessable entity' do
          get :index
          expect(response).to have_http_status :unprocessable_entity
        end
      end

      context 'with read scope and valid resource owner' do
        before do
          allow(controller).to receive(:doorkeeper_token) do
            Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
          end
        end

        it 'shows bookmarks owned by the user' do
          bookmarked_by_user = Fabricate(:bookmark, account: user.account)
          bookmarked_by_others = Fabricate(:bookmark)

          get :index

          expect(assigns(:statuses)).to match_array [bookmarked_by_user.status]
        end

        context 'when registration and post chronology are reversed' do
          let!(:older_status) { Fabricate(:status, account: user.account) }
          let!(:newer_status) { Fabricate(:status, account: user.account) }
          let!(:earlier_registration) { Fabricate(:bookmark, account: user.account, status: newer_status) }
          let!(:later_registration) { Fabricate(:bookmark, account: user.account, status: older_status) }

          it 'returns added order in compact WebUI responses' do
            get :index, params: { compact: true }

            expect(body_as_json[:statuses].map { |status| status[:id] }).to eq [older_status.id.to_s, newer_status.id.to_s]
          end

          it 'keeps registration ids as Link cursors in the first page' do
            get :index, params: { compact: true, limit: 1 }

            expect(body_as_json[:statuses].map { |status| status[:id] }).to eq [older_status.id.to_s]
            next_link = response.headers['Link'].find_link(['rel', 'next']).href
            expect(Rack::Utils.parse_query(URI(next_link).query)['max_id']).to eq later_registration.id.to_s
          end

          it 'can retrieve the next page after the later registration' do
            get :index, params: { compact: true, limit: 1, max_id: later_registration.id }

            expect(body_as_json[:statuses].map { |status| status[:id] }).to eq [newer_status.id.to_s]
          end
        end

        it 'adds pagination headers if necessary' do
          bookmark = Fabricate(:bookmark, account: user.account)

          get :index, params: { limit: 1 }

          expect(response.headers['Link'].find_link(['rel', 'next']).href).to eq "http://test.host/api/v1/bookmarks?limit=1&max_id=#{bookmark.id}"
          expect(response.headers['Link'].find_link(['rel', 'prev']).href).to eq "http://test.host/api/v1/bookmarks?limit=1&min_id=#{bookmark.id}"
        end

        it 'does not add pagination headers if not necessary' do
          get :index

          expect(response.headers['Link']).to eq nil
        end
      end
    end
  end
end
