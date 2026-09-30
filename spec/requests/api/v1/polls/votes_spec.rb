# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Polls Votes' do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'write:statuses' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:poll)    { Fabricate(:poll) }
  let(:poll_id) { poll.id }
  let(:params)  { { choices: %w(1) } }

  describe 'POST /api/v1/polls/:poll_id/votes' do
    subject do
      post "/api/v1/polls/#{poll_id}/votes", params: params, headers: headers, as: :json
    end

    it 'records a valid vote', :aggregate_failures do
      subject

      vote = poll.votes.where(account: user.account).first

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(vote).to_not be_nil
      expect(vote.choice).to eq 1
      expect(poll.reload.cached_tallies).to eq [0, 1]
    end

    context 'with the write scope' do
      let(:scopes) { 'write' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
        expect(poll.votes.where(account: user.account)).to exist
      end
    end

    context 'with a read-only token' do
      let(:scopes) { 'read' }

      it 'returns http forbidden and does not vote' do
        expect { subject }.not_to(change { poll.reload.votes.count })

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'without a token' do
      let(:headers) { {} }

      it 'returns http unauthorized and does not vote' do
        expect { subject }.not_to(change { poll.reload.votes.count })

        expect(response).to have_http_status(401)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'when choices are missing' do
      let(:params) { {} }

      it 'returns the parameter missing error and leaves the poll unchanged', :aggregate_failures do
        expect { subject }.not_to(change { [poll.reload.votes.count, poll.cached_tallies] })

        expect(response).to have_http_status(400)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'param is missing or the value is empty: choices'
      end
    end

    context 'when choices are empty' do
      let(:params) { { choices: [] } }

      it 'returns bad request and does not vote' do
        expect { subject }.not_to(change { [poll.reload.votes.count, poll.cached_tallies] })

        expect(response).to have_http_status(400)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'param is missing or the value is empty: choices'
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

    context 'when the poll is inaccessible' do
      let(:poll) { Fabricate(:poll, status: Fabricate(:status, visibility: :private)) }

      it 'returns http not found and does not vote' do
        expect { subject }.not_to(change { PollVote.count })

        expect(response).to have_http_status(404)
        expect(response.content_type).to start_with('application/json')
        expect(body_as_json[:error]).to eq 'Not Found'
      end
    end
  end
end
