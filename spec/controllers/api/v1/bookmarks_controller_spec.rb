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

        context 'with post-date order' do
          let!(:older_status) { Fabricate(:status, account: user.account) }
          let!(:newer_status) { Fabricate(:status, account: user.account) }

          before do
            # Register the newer post first and the older post last.
            Fabricate(:bookmark, account: user.account, status: newer_status)
            Fabricate(:bookmark, account: user.account, status: older_status)
          end

          it 'keeps the original added order when order is omitted' do
            get :index

            expect(assigns(:statuses).map(&:id)).to eq [older_status.id, newer_status.id]
          end

          it 'shows the newer status first when order=status is requested' do
            get :index, params: { order: 'status' }

            expect(assigns(:statuses).map(&:id)).to eq [newer_status.id, older_status.id]
          end

          it 'paginates status order using status ids and preserves the mode in Link headers' do
            get :index, params: { order: 'status', limit: 1 }

            expect(assigns(:statuses).map(&:id)).to eq [newer_status.id]
            next_link = response.headers['Link'].find_link(['rel', 'next']).href
            previous_link = response.headers['Link'].find_link(['rel', 'prev']).href
            expect(Rack::Utils.parse_query(URI(next_link).query)).to include('order' => 'status', 'max_id' => newer_status.id.to_s)
            expect(Rack::Utils.parse_query(URI(previous_link).query)).to include('order' => 'status', 'min_id' => newer_status.id.to_s)
          end

          it 'supports older, min_id, and since_id cursors in status order' do
            get :index, params: { order: 'status', max_id: newer_status.id }
            expect(assigns(:statuses).map(&:id)).to eq [older_status.id]

            get :index, params: { order: 'status', min_id: older_status.id }
            expect(assigns(:statuses).map(&:id)).to eq [newer_status.id]

            get :index, params: { order: 'status', since_id: older_status.id }
            expect(assigns(:statuses).map(&:id)).to eq [newer_status.id]
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
