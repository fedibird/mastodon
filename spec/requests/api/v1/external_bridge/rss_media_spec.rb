# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS remote media on the owner status' do
  let(:user) { Fabricate(:user) }
  let(:video_url) { 'https://cdn.example/story.mp4' }
  let(:bundle) { external_project_for(user) }

  before do
    bundle[:resource].update!(
      media_candidates: [
        { 'url' => video_url, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/mp4', 'position' => 0, 'description' => 'Clip' },
      ],
      media_revision: 'media-1'
    )
  end

  it 'returns the remote video only to the owning user and not as a downloadable attachment' do
    get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(user)

    expect(response).to have_http_status(200)
    expect(body_as_json[:media_attachments]).to eq []
    expect(body_as_json[:fedibird_external][:media]).to include(
      hash_including(type: 'video', url: video_url, delivery: 'remote', external: true, description: 'Clip')
    )
    expect(body_as_json.to_json).not_to include('remote_url')
  end

  it 'does not give the same account or another user the media URL' do
    roommate = share_account_user(user.account)
    stranger = Fabricate(:user)

    get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(roommate)
    expect(response).to have_http_status(404)
    expect(response.body).not_to include(video_url)

    get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(stranger)
    expect(response).to have_http_status(404)
    expect(response.body).not_to include(video_url)
  end
end