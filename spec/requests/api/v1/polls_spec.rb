# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Polls' do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'read:statuses' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' } }

  describe 'GET /api/v1/polls/:id' do
    subject do
      get "/api/v1/polls/#{poll_id}", headers: headers
    end

    let(:visibility) { 'public' }
    let(:poll)       { Fabricate(:poll, status: Fabricate(:status, visibility: visibility)) }
    let(:poll_id)    { poll.id }

    it 'returns a public poll', :aggregate_failures do
      subject

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(body_as_json[:id]).to eq poll.id.to_s
    end

    context 'with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'with a write-only token' do
      let(:scopes) { 'write:statuses' }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'when the parent status is private' do
      let(:visibility) { 'private' }

      it 'returns http not found' do
        subject

        expect(response).to have_http_status(404)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'Not Found'
      end
    end

    context 'when the poll does not exist' do
      let(:poll_id) { 0 }

      it 'returns http not found' do
        subject

        expect(response).to have_http_status(404)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'Not Found'
      end
    end
  end
end
