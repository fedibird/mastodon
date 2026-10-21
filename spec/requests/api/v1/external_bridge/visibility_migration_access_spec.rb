# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Migrated external projection access' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'migratedowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:admin) { user_with_role('Owner') }
  let(:bundle) { project_for(owner, body: 'Migrated article body') }
  let(:status) { bundle[:status] }
  let(:owner_headers) { auth_headers_for(owner) }
  let(:roommate_headers) { auth_headers_for(roommate) }

  before do
    Setting.external_bridge_external_visibility = false
    bundle
    Favourite.create!(account: owner.account, status: status)
    Bookmark.create!(account: owner.account, status: status)
    Rails.cache.write("statuses/#{status.id}", { 'visibility_ex' => 'personal' })
    Setting.external_bridge_external_visibility = true
    Dir.mktmpdir do |dir|
      ExternalBridge::VisibilityMigration::Runner.call(
        apply: true,
        confirm_readers_ready: true,
        user_id: owner.id,
        checkpoint: File.join(dir, 'checkpoint.json'),
        limit: 10,
        batch_size: 10
      )
    end
  end

  it 'reads the same id as external for the owner and hides it from everyone else' do
    expect(Rails.cache.read("statuses/#{status.id}")).to be_nil
    expect(status.reload.visibility).to eq 'external'

    get "/api/v1/statuses/#{status.id}", headers: owner_headers
    expect(response).to have_http_status(200)
    expect(body_as_json[:id]).to eq status.id.to_s
    expect(body_as_json[:visibility]).to eq 'direct'
    expect(body_as_json[:visibility_ex]).to eq 'external'
    expect(body_as_json[:content]).to include('Migrated article body')

    [roommate_headers, auth_headers_for(stranger), auth_headers_for(admin, 'read:statuses admin:read'), {}].each do |headers|
      get "/api/v1/statuses/#{status.id}", headers: headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Migrated article body')
    end

    get '/api/v1/favourites', headers: owner_headers
    expect(response).to have_http_status(200)
    favourite = body_as_json.find { |row| row[:id] == status.id.to_s }
    expect(favourite[:visibility_ex]).to eq 'external'

    get '/api/v1/bookmarks', headers: owner_headers
    expect(response).to have_http_status(200)
    expect(body_as_json.map { |row| row[:id] }).to include(status.id.to_s)

    enable_external_bridge_rss!(owner)
    get "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/statuses", headers: owner_headers
    expect(response).to have_http_status(200)
    expect(body_as_json.map { |row| row[:id] }).to include(status.id.to_s)

    get "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/statuses", headers: roommate_headers
    expect(response).to have_http_status(404)
  end
end
