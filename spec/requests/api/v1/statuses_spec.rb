# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Statuses' do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'read:statuses' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' } }

  describe 'GET /api/v1/statuses' do
    let(:author)         { Fabricate(:user) }
    let!(:public_status) { Fabricate(:status, account: author.account, visibility: :public) }
    let!(:other_status)  { Fabricate(:status, account: author.account, visibility: :public) }
    let!(:private_status) { Fabricate(:status, account: author.account, visibility: :private) }

    it 'returns the requested public statuses for id[] and omits missing ids', :aggregate_failures do
      get '/api/v1/statuses', params: { id: [public_status.id, other_status.id, 999_999] }, headers: headers

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(status_ids_from_body).to contain_exactly(public_status.id.to_s, other_status.id.to_s)
    end

    it 'keeps accepting the legacy ids[] parameter' do
      get '/api/v1/statuses', params: { ids: [public_status.id, other_status.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(status_ids_from_body).to contain_exactly(public_status.id.to_s, other_status.id.to_s)
    end

    it 'unions id[] and ids[] and returns each status once', :aggregate_failures do
      get '/api/v1/statuses', params: { id: [public_status.id], ids: [public_status.id, other_status.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(status_ids_from_body).to contain_exactly(public_status.id.to_s, other_status.id.to_s)
    end

    it 'omits a private status the requester cannot see' do
      get '/api/v1/statuses', params: { id: [public_status.id, private_status.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(status_ids_from_body).to contain_exactly(public_status.id.to_s)
    end

    it 'returns an empty list when no ids are given' do
      get '/api/v1/statuses', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq []
    end

    context 'when the requester can see the private status' do
      let(:user) { author }

      it 'includes the private status' do
        get '/api/v1/statuses', params: { id: [public_status.id, private_status.id] }, headers: headers

        expect(response).to have_http_status(200)
        expect(status_ids_from_body).to contain_exactly(public_status.id.to_s, private_status.id.to_s)
      end
    end

    context 'without a token' do
      let(:headers) { { 'Accept' => 'application/json' } }

      it 'returns public statuses and omits private ones', :aggregate_failures do
        get '/api/v1/statuses', params: { id: [public_status.id, private_status.id] }, headers: headers

        expect(response).to have_http_status(200)
        expect(status_ids_from_body).to contain_exactly(public_status.id.to_s)
      end
    end

    context 'with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        get '/api/v1/statuses', params: { id: [public_status.id] }, headers: headers

        expect(response).to have_http_status(200)
      end
    end

    context 'with a write-only token' do
      let(:scopes) { 'write:statuses' }

      it 'returns http forbidden' do
        get '/api/v1/statuses', params: { id: [public_status.id] }, headers: headers

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'with the profile scope' do
      let(:scopes) { 'profile' }

      it 'returns http forbidden' do
        get '/api/v1/statuses', params: { id: [public_status.id] }, headers: headers

        expect(response).to have_http_status(403)
      end
    end

    context 'when the unique id count is limited' do
      before do
        stub_const('Api::BaseController::DEFAULT_STATUSES_LIMIT', 2)
      end

      it 'accepts two unique ids' do
        get '/api/v1/statuses', params: { id: [public_status.id, other_status.id] }, headers: headers

        expect(response).to have_http_status(200)
      end

      it 'rejects three unique ids' do
        extra = Fabricate(:status, visibility: :public)

        get '/api/v1/statuses', params: { id: [public_status.id, other_status.id, extra.id] }, headers: headers

        expect(response).to have_http_status(422)
        expect(response.content_type).to start_with('application/json')
      end

      it 'counts ids after removing duplicates' do
        get '/api/v1/statuses', params: { id: [public_status.id, public_status.id], ids: [other_status.id] }, headers: headers

        expect(response).to have_http_status(200)
        expect(status_ids_from_body).to contain_exactly(public_status.id.to_s, other_status.id.to_s)
      end
    end
  end

  def status_ids_from_body
    body_as_json.map { |status| status[:id] }
  end
end
