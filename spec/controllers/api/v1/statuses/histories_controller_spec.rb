# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::HistoriesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:statuses' }
  let(:status) { Fabricate(:status, account: user.account, text: 'original history', visibility: :public) }

  describe 'GET #show' do
    context 'with an oauth token' do
      before do
        allow(controller).to receive(:doorkeeper_token) { token }
      end

      it 'returns one synthetic snapshot for a status that has not been edited' do
        get :show, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq 1
        expect(body_as_json.first[:content]).to include('original history')
        expect(Time.zone.parse(body_as_json.first[:created_at])).to be_within(1.second).of(status.created_at)
        expect(body_as_json.first[:account][:id]).to eq user.account.id.to_s
      end

      it 'returns stored snapshots from oldest to newest' do
        allow(DistributionWorker).to receive(:perform_async)
        allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async)
        allow(LinkCrawlWorker).to receive(:perform_async)
        UpdateStatusService.new.call(status, user.account.id, text: 'edited history')

        get :show, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(body_as_json.first[:content]).to include('original history')
        expect(body_as_json.last[:content]).to include('edited history')
      end

      it 'renders a snapshot whose editor account was removed' do
        status.snapshot!(at_time: status.created_at, rate_limit: false)
        status.edits.last.update!(account: nil)

        get :show, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(body_as_json.first[:account]).to be_nil
      end

      context 'with a private status the viewer cannot see' do
        let(:status) { Fabricate(:status, visibility: :private, text: 'secret') }

        it 'returns http not found' do
          get :show, params: { status_id: status.id }
          expect(response).to have_http_status(404)
        end
      end
    end

    context 'without an oauth token' do
      it 'returns the public history' do
        get :show, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq 1
      end

      it 'returns http not found for a private status' do
        hidden = Fabricate(:status, visibility: :private, text: 'secret')

        get :show, params: { status_id: hidden.id }

        expect(response).to have_http_status(404)
      end
    end
  end
end
