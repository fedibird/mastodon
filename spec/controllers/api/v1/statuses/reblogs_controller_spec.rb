# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Statuses::ReblogsController do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:app)   { Fabricate(:application, name: 'Test app', website: 'http://testapp.com') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:statuses', application: app) }

  context 'with an oauth token' do
    before do
      allow(controller).to receive(:doorkeeper_token) { token }
    end

    describe 'POST #create' do
      let(:status) { Fabricate(:status, account: user.account) }

      before do
        post :create, params: { status_id: status.id }
      end

      context 'with public status' do
        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'updates the reblogs count' do
          expect(status.reblogs.count).to eq 1
        end

        it 'updates the reblogged attribute' do
          expect(user.account.reblogged?(status)).to be true
        end

        it 'returns json with updated attributes' do
          hash_body = body_as_json

          expect(hash_body[:reblog][:id]).to eq status.id.to_s
          expect(hash_body[:reblog][:reblogs_count]).to eq 1
          expect(hash_body[:reblog][:reblogged]).to be true
        end
      end

      context 'with private status of not-followed account' do
        let(:status) { Fabricate(:status, visibility: :private) }

        it 'returns http not found' do
          expect(response).to have_http_status(404)
        end
      end
    end

    describe 'POST #create with mutual visibility' do
      let(:status) { Fabricate(:status, account: user.account) }
      let(:mutual) { Fabricate(:account) }
      let(:stranger) { Fabricate(:account) }

      before do
        mutual.follow!(user.account)
        user.account.follow!(mutual)
        stranger.follow!(user.account)
      end

      it 'addresses only mutual followers' do
        post :create, params: { status_id: status.id, visibility: 'mutual' }

        boost = user.account.statuses.find_by!(reblog_of_id: status.id)
        expect(response).to have_http_status(200)
        expect(boost.visibility).to eq 'limited'
        expect(boost.mentions.pluck(:account_id)).to contain_exactly(mutual.id)
      end

      it 'addresses only mutual followers when reboost is off' do
        user.settings.enable_reboost = false

        post :create, params: { status_id: status.id, visibility: 'mutual' }

        boost = user.account.statuses.find_by!(reblog_of_id: status.id)
        expect(response).to have_http_status(200)
        expect(boost.mentions.pluck(:account_id)).to contain_exactly(mutual.id)
      end

      it 'addresses only mutual followers on a reboost' do
        ReblogService.new.call(user.account, status, visibility: 'limited', circle: user.account, visibility_explicit: true)

        travel 301.seconds do
          post :create, params: { status_id: status.id, visibility: 'mutual', reboost: true }
        end

        boost = user.account.statuses.find_by!(reblog_of_id: status.id)
        expect(response).to have_http_status(200)
        expect(boost.mentions.pluck(:account_id)).to contain_exactly(mutual.id)
      end
    end

    describe 'POST #destroy' do
      context 'with public status' do
        let(:status) { Fabricate(:status, account: user.account) }

        before do
          ReblogService.new.call(user.account, status)
          post :destroy, params: { status_id: status.id }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'updates the reblogs count' do
          expect(status.reblogs.count).to eq 0
        end

        it 'updates the reblogged attribute' do
          expect(user.account.reblogged?(status)).to be false
        end

        it 'returns json with updated attributes' do
          hash_body = body_as_json

          expect(hash_body[:id]).to eq status.id.to_s
          expect(hash_body[:reblogs_count]).to eq 0
          expect(hash_body[:reblogged]).to be false
        end
      end

      context 'with public status when blocked by its author' do
        let(:status) { Fabricate(:status, account: user.account) }

        before do
          ReblogService.new.call(user.account, status)
          status.account.block!(user.account)
          post :destroy, params: { status_id: status.id }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'updates the reblogs count' do
          expect(status.reblogs.count).to eq 0
        end

        it 'updates the reblogged attribute' do
          expect(user.account.reblogged?(status)).to be false
        end

        it 'returns json with updated attributes' do
          hash_body = body_as_json

          expect(hash_body[:id]).to eq status.id.to_s
          expect(hash_body[:reblogs_count]).to eq 0
          expect(hash_body[:reblogged]).to be false
        end
      end

      context 'with private status that was not reblogged' do
        let(:status) { Fabricate(:status, visibility: :private) }

        before do
          post :destroy, params: { status_id: status.id }
        end

        it 'returns http not found' do
          expect(response).to have_http_status(404)
        end
      end
    end

    describe 'POST #destroy before RemovalWorker runs' do
      let(:status) { Fabricate(:status, account: user.account) }

      it 'returns the decremented count while the reblog row is only discarded' do
        ReblogService.new.call(user.account, status)

        Sidekiq::Testing.fake! do
          RemovalWorker.jobs.clear
          post :destroy, params: { status_id: status.id }

          expect(response).to have_http_status(200)
          expect(RemovalWorker.jobs.size).to eq 1
          expect(status.reload.reblogs_count).to eq 1

          hash_body = body_as_json
          expect(hash_body[:id]).to eq status.id.to_s
          expect(hash_body[:reblogs_count]).to eq 0
          expect(hash_body[:reblogged]).to be false

          RemovalWorker.drain
        end

        expect(status.reload.reblogs_count).to eq 0
        expect(user.account.reblogged?(status)).to be false
      end

      it 'decrements by one when other reblogs remain' do
        ReblogService.new.call(Fabricate(:account), status)
        ReblogService.new.call(user.account, status)
        expect(status.reload.reblogs_count).to eq 2

        Sidekiq::Testing.fake! do
          post :destroy, params: { status_id: status.id }

          expect(response).to have_http_status(200)
          expect(status.reload.reblogs_count).to eq 2
          expect(body_as_json[:reblogs_count]).to eq 1
          expect(body_as_json[:reblogged]).to be false
        end
      end

      it 'cancels a pending reboost so a later resume cannot recreate it' do
        operation = ReboostOperation.create!(
          account: user.account,
          reblog_of_id: status.id,
          state: 'pending',
          reboost: true,
          undo_inboxes: [],
          options: {}
        )

        post :destroy, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(operation.reload).to have_attributes(state: 'cancelled', error_code: 'unreblogged')
      end

      it 'keeps the current count when the status is not reblogged' do
        ReblogService.new.call(Fabricate(:account), status)
        expect(status.reload.reblogs_count).to eq 1

        Sidekiq::Testing.fake! do
          RemovalWorker.jobs.clear
          post :destroy, params: { status_id: status.id }

          expect(response).to have_http_status(200)
          expect(RemovalWorker.jobs).to be_empty
          expect(status.reload.reblogs_count).to eq 1
          expect(body_as_json[:reblogs_count]).to eq 1
          expect(body_as_json[:reblogged]).to be false
        end
      end
    end

    describe 'GET #show' do
      let(:status) { Fabricate(:status, account: user.account) }

      it 'returns the requested operation instead of a newer one' do
        older = ReboostOperation.create!(
          account: user.account,
          reblog_of_id: status.id,
          state: 'cancelled',
          error_code: 'unreblogged',
          reboost: true,
          undo_inboxes: [],
          options: {}
        )
        ReboostOperation.create!(
          account: user.account,
          reblog_of_id: status.id,
          state: 'federating',
          reboost: true,
          undo_inboxes: [],
          options: {}
        )

        get :show, params: { status_id: status.id, operation_id: older.id }

        expect(response).to have_http_status(200)
        expect(body_as_json).to include(id: older.id.to_s, state: 'cancelled', error: 'unreblogged', new_status_id: nil)
      end

      it 'keeps a cancelled operation cancelled after Undo delivery' do
        operation = ReboostOperation.create!(
          account: user.account,
          reblog_of_id: status.id,
          state: 'pending',
          reboost: true,
          undo_payload: '{"type":"Undo"}',
          undo_inboxes: ['https://remote.example/inbox'],
          options: {}
        )
        allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)

        post :destroy, params: { status_id: status.id }
        get :show, params: { status_id: status.id, operation_id: operation.id }

        expect(response).to have_http_status(200)
        expect(body_as_json).to include(id: operation.id.to_s, state: 'cancelled', new_status_id: nil)
        expect(operation.reload.undo_enqueued_at).to be_present
        expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
      end
    end

    describe 'POST #create reboost' do
      let(:status) { Fabricate(:status, account: user.account) }

      it 'reboosts into a new wrapper' do
        ReblogService.new.call(user.account, status)
        travel 301.seconds do
          post :create, params: { status_id: status.id, reboost: true }

          expect(response).to have_http_status(200)
          expect(body_as_json[:reblog][:id]).to eq status.id.to_s
          expect(body_as_json[:reblog][:reblogged]).to be true
          expect(body_as_json[:reblog][:reblogs_count]).to eq 1
          expect(user.account.statuses.where(reblog_of_id: status.id).count).to eq 1
        end
      end

      it 'rejects a non-boolean reboost flag' do
        post :create, params: { status_id: status.id, reboost: 'yes' }

        expect(response).to have_http_status(400)
      end

      it 'returns retry-after while the cooldown is active' do
        ReblogService.new.call(user.account, status)
        post :create, params: { status_id: status.id, reboost: true }

        expect(response).to have_http_status(429)
        expect(response.headers['Retry-After'].to_i).to be_positive
        expect(body_as_json[:retry_after]).to be_positive
      end

      it 'rejects reboost when the acceptance policy leaves it off' do
        user.settings.new_features_policy = 'conservative'
        ReblogService.new.call(user.account, status)
        travel 301.seconds do
          post :create, params: { status_id: status.id, reboost: true }

          expect(response).to have_http_status(403)
        end
        expect(user.account.statuses.where(reblog_of_id: status.id).count).to eq 1
      end
    end
  end
end
