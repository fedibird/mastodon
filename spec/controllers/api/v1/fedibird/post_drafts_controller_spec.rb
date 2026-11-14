# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PostDraftsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }

  def authorize(owner, scopes)
    controller.instance_variable_set(:@current_user, nil)
    token = Fabricate(:accessible_access_token, resource_owner_id: owner&.id, scopes: scopes)
    allow(controller).to receive(:doorkeeper_token) { token }
    token
  end

  def reset_request_body
    controller.instance_variable_set(:@json_body, nil)
  end

  def draft_body(text = 'hello', uuid_value: uuid)
    {
      client_uuid: uuid_value,
      payload: {
        schema_version: 1,
        input: { text: text, privacy: 'personal', media: [] },
      },
    }
  end

  def create_draft(text = 'hello', uuid_value: uuid)
    reset_request_body
    post :create, body: draft_body(text, uuid_value: uuid_value).to_json, as: :json
  end

  describe 'authorization' do
    it 'rejects the ordinary read and write scopes' do
      %w(read read:statuses write write:statuses).each do |scope|
        authorize(user, scope)
        get :index

        expect(response).to have_http_status(403)
        expect(response.body).not_to include('hello')
      end
    end

    it 'rejects a missing token and a client-credentials token' do
      allow(controller).to receive(:doorkeeper_token) { nil }
      get :index
      expect(response).to have_http_status(401)

      authorize(nil, 'read:post_drafts')
      get :index
      expect(response).to have_http_status(422)
    end
  end

  describe 'owner access' do
    before { authorize(user, 'read:post_drafts write:post_drafts') }

    it 'creates, lists a preview, and reads the payload for the owner only' do
      statuses = Status.count
      create_draft('saved personal note')

      expect(response).to have_http_status(201)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      body = body_as_json
      expect(body[:revision]).to eq 1
      expect(body[:media_retained]).to be true
      expect(body[:media_restore]).to eq 'complete'
      expect(body[:media]).to eq []
      expect(body[:payload][:input][:privacy]).to eq 'personal'
      expect(Status.count).to eq statuses

      get :index
      listed = body_as_json
      expect(listed.length).to eq 1
      expect(listed.first).not_to have_key(:payload)
      expect(listed.first[:preview][:text]).to eq 'saved personal note'
      expect(response.headers['X-Post-Draft-Limit']).to eq '100'
      expect(response.headers['X-Post-Draft-Count']).to eq '1'

      other = Fabricate(:user)
      authorize(other, 'read:post_drafts write:post_drafts')
      get :show, params: { id: body[:draft_id] }
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('saved personal note')

      reset_request_body
      patch :update, params: { id: body[:draft_id] }, body: { expected_revision: 1, payload: draft_body('stolen')[:payload] }.to_json, as: :json
      expect(response).to have_http_status(404)
      expect(PostDraft.find(body[:draft_id]).payload.dig('input', 'text')).to eq 'saved personal note'

      reset_request_body
      delete :destroy, params: { id: body[:draft_id] }, body: { expected_revision: 1 }.to_json, as: :json
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('saved personal note')
      expect(PostDraft.find(body[:draft_id]).payload.dig('input', 'text')).to eq 'saved personal note'
    end

    it 'returns the same draft when the create is repeated and conflicts when the text differs' do
      create_draft('hello')
      first = body_as_json
      create_draft('hello')

      expect(response).to have_http_status(200)
      expect(body_as_json[:draft_id]).to eq first[:draft_id]
      expect(body_as_json[:revision]).to eq 1

      create_draft('changed')
      expect(response).to have_http_status(409)
      expect(body_as_json[:revision]).to eq 1
      expect(response.body).not_to include('changed')
    end

    it 'pages the list without returning another page of the payload' do
      create_draft('one', uuid_value: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
      create_draft('two', uuid_value: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2')
      create_draft('three', uuid_value: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3')

      get :index, params: { limit: 2 }
      page = body_as_json
      expect(page.map { |item| item[:preview][:text] }.length).to eq 2
      expect(response.headers['Link'].to_s).to include('max_id=')

      max_id = response.headers['Link'].to_s[/max_id=(\d+)/, 1]
      get :index, params: { limit: 2, max_id: max_id }
      expect(body_as_json.length).to eq 1
    end

    it 'requires the write scope to update and deletes only the addressed draft' do
      create_draft('hello')
      draft_id = body_as_json[:draft_id]
      authorize(user, 'read:post_drafts')
      reset_request_body
      patch :update, params: { id: draft_id }, body: { expected_revision: 1, payload: draft_body('next')[:payload] }.to_json, as: :json
      expect(response).to have_http_status(403)

      authorize(user, 'write:post_drafts')
      reset_request_body
      patch :update, params: { id: draft_id }, body: { expected_revision: 1, payload: draft_body('next')[:payload] }.to_json, as: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:revision]).to eq 2
      expect(body_as_json[:media_retained]).to be true
      expect(body_as_json[:media_restore]).to eq 'complete'

      reset_request_body
      delete :destroy, params: { id: draft_id }, body: { expected_revision: 2 }.to_json, as: :json
      expect(response).to have_http_status(200)
      expect(response.body).not_to include('next')
      expect(PostDraft.where(id: draft_id)).to be_empty
    end

    it 'refuses to delete a draft from an older revision' do
      create_draft('hello')
      draft_id = body_as_json[:draft_id]
      reset_request_body
      patch :update, params: { id: draft_id }, body: { expected_revision: 1, payload: draft_body('edited')[:payload] }.to_json, as: :json
      expect(response).to have_http_status(200)

      reset_request_body
      delete :destroy, params: { id: draft_id }, body: { expected_revision: 1 }.to_json, as: :json
      expect(response).to have_http_status(409)
      expect(body_as_json[:revision]).to eq 2
      expect(response.body).not_to include('edited')
      expect(PostDraft.find(draft_id).payload.dig('input', 'text')).to eq 'edited'

      reset_request_body
      delete :destroy, params: { id: draft_id }, body: { expected_revision: '2' }.to_json, as: :json
      expect(response).to have_http_status(422)
      expect(PostDraft.find(draft_id).payload.dig('input', 'text')).to eq 'edited'

      reset_request_body
      delete :destroy, params: { id: draft_id }, body: { expected_revision: 2 }.to_json, as: :json
      expect(response).to have_http_status(200)
      expect(response.body).not_to include('edited')
      expect(PostDraft.where(id: draft_id)).to be_empty
    end
  end

  describe 'retained media' do
    before { authorize(user, 'read:post_drafts write:post_drafts') }

    def media_payload(text, attachments)
      {
        client_uuid: uuid,
        payload: {
          schema_version: 1,
          input: {
            text: text,
            privacy: 'personal',
            media: attachments,
          },
        },
      }
    end

    it 'returns the server file, alt, and focus to another token in draft order' do
      first = Fabricate(:media_attachment, account: user.account, description: "one\nline")
      second = Fabricate(:media_attachment, account: user.account, description: 'two')
      first.update!(focus: '0.25,-0.5')
      reset_request_body
      post :create, body: media_payload('photos', [
        { id: second.id.to_s, order: 1, description: 'stale two', focus: { x: 0, y: 0 } },
        { id: first.id.to_s, order: 0, description: 'stale one', focus: { x: 0, y: 0 } },
      ]).to_json, as: :json

      expect(response).to have_http_status(201)
      created = body_as_json
      expect(created[:media_retained]).to be true
      expect(created[:media_restore]).to eq 'complete'
      expect(created[:media].map { |item| item[:id] }).to eq [first.id.to_s, second.id.to_s]
      expect(created[:media].first[:description]).to eq "one\nline"
      expect(created[:media].first[:type]).to eq 'image'
      expect(created[:media].first[:url]).to be_present
      expect(created[:media].first.dig(:meta, :focus, :x)).to eq 0.25
      expect(created[:payload][:input][:media].first[:description]).to eq 'stale one'
      expect(created[:payload][:input][:media].first).not_to have_key(:url)
      expect(first.reload.description).to eq "one\nline"

      get :index
      expect(body_as_json.first).not_to have_key(:media)
      expect(body_as_json.first[:media_count]).to eq 2

      other_token = authorize(user, 'read:post_drafts')
      expect(other_token).to be_present
      get :show, params: { id: created[:draft_id] }
      expect(response).to have_http_status(200)
      expect(body_as_json[:media].map { |item| item[:id] }).to eq [first.id.to_s, second.id.to_s]

      stranger = Fabricate(:media_attachment, account: Fabricate(:account))
      reset_request_body
      authorize(user, 'write:post_drafts')
      post :create, body: media_payload('stolen', [{ id: stranger.id.to_s }]).merge(client_uuid: '33333333-3333-4333-8333-333333333333').to_json, as: :json
      expect(response).to have_http_status(422)
      expect(body_as_json[:errors].first[:code]).to eq 'media_forbidden'
      expect(PostDraft.where(account_id: user.account_id).count).to eq 1
      expect(stranger.reload).to be_persisted
    end
  end
end
