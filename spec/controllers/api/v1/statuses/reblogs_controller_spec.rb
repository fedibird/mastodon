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
  end
end
