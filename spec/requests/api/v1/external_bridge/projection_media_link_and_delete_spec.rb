# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External projection media link and delete' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'projectionowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:bundle) { external_project_for(owner, body: 'Imported article') }
  let(:status) { bundle[:status] }
  let(:owner_headers) { auth_headers_for(owner) }
  let(:roommate_headers) { auth_headers_for(roommate) }
  let(:stranger_headers) { auth_headers_for(stranger) }

  def attach_images(record, count)
    now = Time.current
    count.times do
      MediaAttachment.insert(
        {
          account_id: record.account_id,
          status_id: record.id,
          remote_url: '',
          file_file_name: 'pixel.jpg',
          file_content_type: 'image/jpeg',
          file_file_size: 8,
          type: 0,
          created_at: now,
          updated_at: now,
        }
      )
    end
    record.media_attachments.reset
  end

  before { attach_images(status, 5) }

  describe 'GET /api/v1/statuses/:id' do
    it 'omits the compatibility link from the owner content and hides the row from other users' do
      get "/api/v1/statuses/#{status.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:content]).to include('Imported article')
      expect(body_as_json[:content]).not_to include('original-media-link')
      expect(body_as_json[:content]).not_to include('href=""')
      expect(body_as_json[:content]).not_to include(bundle[:resource].canonical_url)
      expect(body_as_json[:url]).to be_nil

      get "/api/v1/statuses/#{status.id}", headers: roommate_headers
      expect(response).to have_http_status(404)

      get "/api/v1/statuses/#{status.id}", headers: stranger_headers
      expect(response).to have_http_status(404)
    end

    it 'still returns the compatibility link for an ordinary status with five attachments' do
      ordinary = Fabricate(:status, account: owner.account, text: 'Ordinary note', visibility: :public)
      attach_images(ordinary, 5)

      get "/api/v1/statuses/#{ordinary.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:content]).to include('original-media-link')
      expect(body_as_json[:content]).to include('Attached: 5 images')
      expect(body_as_json[:content]).not_to include('href=""')
    end
  end

  describe 'DELETE /api/v1/statuses/:id' do
    it 'returns only the id for the owner and does not redraft or federate the projection' do
      expect(RemovalWorker).not_to receive(:perform_async)

      delete "/api/v1/statuses/#{status.id}", params: { redraft: true }, headers: owner_headers

      payload = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(payload.keys).to eq ['id']
      expect(payload['id']).to eq status.id.to_s
      expect(Status.unscoped.exists?(status.id)).to be false
      expect(ExternalStatusProjection.exists?(bundle[:marker].id)).to be false
      expect(ExternalProjectionSuppression.exists?(user_id: owner.id, external_resource_id: bundle[:resource].id)).to be true
    end

    it 'refuses the other user of the same account and a stranger without deleting the row' do
      delete "/api/v1/statuses/#{status.id}", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(Status.exists?(status.id)).to be true

      delete "/api/v1/statuses/#{status.id}", headers: stranger_headers
      expect(response).to have_http_status(404)
      expect(Status.exists?(status.id)).to be true
      expect(ExternalProjectionSuppression.where(user_id: owner.id, external_resource_id: bundle[:resource].id)).to be_empty
    end

    it 'does not resurrect the projection when the resource is materialized again' do
      enable_external_bridge_rss!(owner)
      resource = bundle[:resource]

      delete "/api/v1/statuses/#{status.id}", headers: owner_headers
      expect(response).to have_http_status(200)

      result = ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription].reload, resources: [resource.reload])

      expect(result.skipped).to eq 1
      expect(result.succeeded).to eq 0
      expect(ExternalStatusProjection.where(user_id: owner.id, external_resource_id: resource.id)).to be_empty
      expect(Status.unscoped.exists?(status.id)).to be false
    end

    it 'keeps the ordinary delete payload, including the account and text' do
      ordinary = Fabricate(:status, account: owner.account, text: 'Ordinary note', visibility: :public)

      delete "/api/v1/statuses/#{ordinary.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq ordinary.id.to_s
      expect(body_as_json[:text]).to eq 'Ordinary note'
      expect(body_as_json[:account][:id]).to eq owner.account_id.to_s
      expect(body_as_json).not_to have_key(:content)
    end
  end
end
