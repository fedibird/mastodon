# frozen_string_literal: true

# The examples share one HTTP access matrix.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'External visibility HTTP access' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'extreader')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:admin) { user_with_role('Owner') }
  let(:bundle) { external_project_for(owner, body: 'External owner article') }
  let(:status) { bundle[:status] }
  let(:owner_headers) { auth_headers_for(owner) }
  let(:roommate_headers) { auth_headers_for(roommate) }
  let(:stranger_headers) { auth_headers_for(stranger) }
  let(:admin_headers) { auth_headers_for(admin, 'read:statuses write:statuses admin:read admin:write') }

  before { bundle }

  describe 'GET /api/v1/statuses/:id' do
    it 'returns direct plus visibility_ex external to the marker owner only' do
      get "/api/v1/statuses/#{status.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:visibility]).to eq 'direct'
      expect(body_as_json[:visibility_ex]).to eq 'external'
      expect(body_as_json[:fedibird_external]).to include(protocol: 'rss', canonical_url: 'https://example.com/posts/external', interaction: 'local_only')
      expect(body_as_json[:content]).to include('External owner article')
      expect(body_as_json[:visibility]).not_to eq 'external'

      [roommate_headers, stranger_headers, admin_headers, {}].each do |headers|
        get "/api/v1/statuses/#{status.id}", headers: headers
        expect(response).to have_http_status(404)
        expect(response.body).not_to include('External owner article')
      end
    end

    it 'hides the row from context, source, and the other user of the same account' do
      parent = Fabricate(:status, account: stranger.account, text: 'Public parent', visibility: :public)
      get "/api/v1/statuses/#{parent.id}/context", headers: stranger_headers
      expect(response).to have_http_status(200)
      expect(response.body).not_to include(status.id.to_s)

      get "/api/v1/statuses/#{status.id}/context", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('External owner article')

      get "/api/v1/statuses/#{status.id}/source", headers: owner_headers
      expect(response).to have_http_status(200)

      get "/api/v1/statuses/#{status.id}/source", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('External owner article')

      get "/api/v1/accounts/#{owner.account_id}/statuses", headers: owner_headers
      expect(response.body).not_to include('External owner article')
    end
  end

  describe 'local actions' do
    it 'lets the owner favourite and bookmark and refuses everyone else' do
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      expect(Trends.statuses).not_to receive(:register)

      post "/api/v1/statuses/#{status.id}/favourite", headers: owner_headers
      expect(response).to have_http_status(200)
      post "/api/v1/statuses/#{status.id}/bookmark", headers: owner_headers
      expect(response).to have_http_status(200)

      get '/api/v1/favourites?compact=true', headers: owner_headers
      expect(response.body).to include(status.id.to_s)
      expect(response.body).not_to include('"visibility":"external"')

      get '/api/v1/favourites?compact=true', headers: roommate_headers
      expect(response.body).not_to include(status.id.to_s)
      get '/api/v1/bookmarks', headers: admin_headers
      expect(response.body).not_to include(status.id.to_s)

      post "/api/v1/statuses/#{status.id}/unfavourite", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(Favourite.where(account: owner.account, status: status)).to exist

      post "/api/v1/statuses/#{status.id}/unfavourite", headers: owner_headers
      expect(response).to have_http_status(200)
      post "/api/v1/statuses/#{status.id}/unbookmark", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(Favourite.where(status: status)).not_to exist
      expect(Bookmark.where(status: status)).not_to exist
    end

    it 'refuses reply, boost, quote, edit, pin, and a visibility change' do
      expect do
        PostStatusService.new.call(owner.account, text: 'reply', thread: status, visibility: 'public')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        ReblogService.new.call(owner.account, status)
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PostStatusService.new.call(owner.account, text: 'quote', quote_id: status.id, visibility: 'public')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        UpdateStatusService.new.call(status, owner.account_id, text: 'changed')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PinService.new.call(owner.account, status)
      end.to raise_error(Mastodon::ValidationError)

      patch "/api/v1/statuses/#{status.id}", params: { status: 'changed', visibility: 'public' }, headers: owner_headers
      expect(response).to have_http_status(403)
      expect(status.reload.text).to eq 'External owner article'
      expect(status.visibility).to eq 'external'

      delete "/api/v1/statuses/#{status.id}", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(Status.exists?(status.id)).to be true
    end
  end

  describe 'write API' do
    it 'rejects external, numeric 201, and visibility_ex without creating a public status' do
      before = Status.count
      [
        { status: 'picked external', visibility: 'external' },
        { status: 'picked numeric', visibility: '201' },
        { status: 'picked extension', visibility_ex: 'external' },
        { status: 'picked later', visibility: 'external', scheduled_at: 2.hours.from_now.iso8601 },
      ].each do |params|
        post '/api/v1/statuses', params: params, headers: owner_headers
        expect(response).to have_http_status(422), response.body
        expect(response.body).not_to include(params[:status])
      end

      expect(Status.count).to eq before
      expect(owner.account.scheduled_statuses).to be_empty
      expect(Status.where(visibility: Status.visibilities[:external]).where.not(id: status.id)).to be_empty
    end
  end

  describe 'owner list and personal timeline' do
    it 'lists the external item for the subscribing user and keeps it off the personal timeline' do
      legacy = project_for(owner, body: 'Legacy still personal')
      ordinary = PostStatusService.new.call(owner.account, text: 'Still my personal note', visibility: 'personal')

      owner_ids = PersonalFeed.new(owner.account, viewer_user_id: owner.id).get(40).map(&:id)
      expect(owner_ids).to include(legacy[:status].id, ordinary.id)
      expect(owner_ids).not_to include(status.id)

      get '/api/v1/timelines/personal', headers: owner_headers
      expect(response).to have_http_status(200)
      expect(response.body).to include('Still my personal note')
      expect(response.body).not_to include('External owner article')

      get "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/statuses", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(body_as_json.first[:canonical_url]).to eq 'https://example.com/posts/external'

      get "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/statuses", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('External owner article')
    end
  end

  describe 'HTML' do
    before do
      allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
      allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
        with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
      end
    end

    it 'shows the text to the signed-in owner and not to an admin session' do
      sign_in owner
      get "/@#{owner.account.username}/#{status.id}"
      expect(response).to have_http_status(200)
      expect(response.body).to include('External owner article')

      sign_out owner
      sign_in admin
      get "/@#{owner.account.username}/#{status.id}"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('External owner article')
    end
  end
end
# rubocop:enable Metrics/BlockLength
