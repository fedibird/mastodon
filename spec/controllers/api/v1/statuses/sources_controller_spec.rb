# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::SourcesController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:statuses' }
  let(:status) { Fabricate(:status, text: 'hello source', spoiler_text: 'cw') }

  describe 'GET #show' do
    context 'with an oauth token' do
      before do
        allow(controller).to receive(:doorkeeper_token) { token }
      end

      it 'returns the unformatted status source' do
        get :show, params: { status_id: status.id }

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq(
          id: status.id.to_s,
          text: 'hello source',
          spoiler_text: 'cw'
        )
      end

      context 'with insufficient scope' do
        let(:scopes) { 'write:statuses' }

        it 'returns http forbidden' do
          get :show, params: { status_id: status.id }
          expect(response).to have_http_status(403)
        end
      end

      context 'with a private status of a non-followed account' do
        let(:status) { Fabricate(:status, visibility: :private, text: 'secret', spoiler_text: '') }

        it 'returns http not found' do
          get :show, params: { status_id: status.id }
          expect(response).to have_http_status(404)
        end
      end

      context 'with a private status of a followed account' do
        let(:status) { Fabricate(:status, visibility: :private, text: 'secret', spoiler_text: 'hidden') }

        before { user.account.follow!(status.account) }

        it 'returns the unformatted status source' do
          get :show, params: { status_id: status.id }

          expect(response).to have_http_status(200)
          expect(body_as_json).to eq(
            id: status.id.to_s,
            text: 'secret',
            spoiler_text: 'hidden'
          )
        end
      end
    end

    context 'without an oauth token' do
      it 'returns http unauthorized' do
        get :show, params: { status_id: status.id }
        expect(response).to have_http_status(401)
      end
    end
  end
end
