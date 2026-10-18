# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Fedibird::ReadingBookmarksController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses write:statuses read:lists write:lists') }
  let(:status_id) { Fabricate(:status, account: user.account, visibility: :public, text: 'public-body-phrase').id.to_s }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def anchor(id = status_id)
    {
      version: 1,
      status_id: id,
      display_row_id: id,
      offset_px: 12,
      alignment: 'top',
      captured_at: '2026-10-18T00:00:00Z',
    }
  end

  def create_place(extra = {})
    post :create, params: { name: 'Morning', source: 'home', anchor: anchor }.merge(extra)
  end

  describe 'POST #create' do
    it 'stores a named anchor for the owner and omits the status body' do
      expect { create_place }.to change(TimelineReadingBookmark, :count).by(1)
        .and not_change(Bookmark, :count)
        .and not_change(Marker, :count)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(201)
      expect(body['source']).to eq('home')
      expect(body['source_timeline_id']).to eq('home')
      expect(body['anchor']['status_id']).to eq(status_id)
      expect(body['availability']['resume']).to eq('manual')
      expect(body['availability']['anchor']).to eq('visible')
      expect(body['availability']['membership']).to eq('unchecked')
      expect(body['lock_version']).to eq(0)
      expect(response.body).not_to include('public-body-phrase')
      expect(TimelineReadingBookmark.last.context.to_json).not_to include('public-body-phrase')
    end

    it 'does not save search text or a window' do
      expect { create_place(context: { q: 'hidden-query-zz' }) }.not_to change(TimelineReadingBookmark, :count)

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)['error']).to eq('search_or_content_not_accepted')
      expect(response.body).not_to include('hidden-query-zz')

      expect { create_place(statuses: [status_id]) }.not_to change(TimelineReadingBookmark, :count)
      expect(JSON.parse(response.body)['error']).to eq('window_not_accepted')
    end

    it 'does not disclose another account list or a user account used as a group' do
      list = Fabricate(:list, account: Fabricate(:user).account, title: 'foreign-list-title-xyz')

      expect { create_place(source: 'list', context: { id: list.id.to_s }) }.not_to change(TimelineReadingBookmark, :count)
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('foreign-list-title-xyz')

      expect { create_place(source: 'group', context: { id: user.account_id.to_s }) }.not_to change(TimelineReadingBookmark, :count)
      expect(response).to have_http_status(404)
    end

    it 'rejects a remote group and a spoofed source id' do
      remote = Fabricate(:account, actor_type: 'Group', domain: 'remote.test', username: 'remote_group_name')

      create_place(source: 'group', context: { id: remote.id.to_s })
      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)['error']).to eq('remote_group')
      expect(response.body).not_to include('remote_group_name')

      create_place(source: 'home', source_timeline_id: 'list:4')
      expect(JSON.parse(response.body)['error']).to eq('source_mismatch')
    end

    it 'rejects a duplicate name and the next row past the cap' do
      create_place
      create_place(name: 'Morning')
      expect(JSON.parse(response.body)['error']).to eq('duplicate_name')

      stub_const('TimelineReadingBookmark::PER_USER_LIMIT', 1)
      create_place(name: 'Second')
      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)['error']).to eq('limit')
      expect(user.timeline_reading_bookmarks.count).to eq(1)
    end

    it 'requires the list scope when the source is a list' do
      list = Fabricate(:list, account: user.account, title: 'owned-list-title')
      narrow = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses write:statuses')
      allow(controller).to receive(:doorkeeper_token) { narrow }

      create_place(source: 'list', context: { id: list.id.to_s })
      expect(response).to have_http_status(403)
      expect(user.timeline_reading_bookmarks).to be_empty

      allow(controller).to receive(:doorkeeper_token) { token }
      create_place(source: 'list', context: { id: list.id.to_s }, name: 'Owned')
      body = JSON.parse(response.body)
      expect(response).to have_http_status(201)
      expect(body['source_label']).to eq('owned-list-title')
      expect(body['context']).to eq('id' => list.id.to_s)
    end

    it 'reports a direct status as not found and does not return its text' do
      secret = Fabricate(:status, visibility: :direct, text: 'direct-leak-phrase')

      create_place(anchor: anchor(secret.id.to_s))
      body = JSON.parse(response.body)

      expect(body['availability']['anchor']).to eq('not_found')
      expect(response.body).not_to include('direct-leak-phrase')
    end
  end

  describe 'GET #index and #show' do
    it 'returns only the signed-in user rows' do
      create_place(name: 'private-bookmark-name')
      id = JSON.parse(response.body)['id']
      other = Fabricate(:user)
      other_token = Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'read:statuses write:statuses')
      allow(controller).to receive(:doorkeeper_token) { other_token }
      controller.instance_variable_set(:@current_user, nil)

      get :index
      expect(JSON.parse(response.body)).to eq([])

      get :show, params: { id: id }
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('private-bookmark-name')
    end

    it 'marks a deleted list missing and a blocked group inaccessible' do
      list = Fabricate(:list, account: user.account, title: 'morning-list-title-xyz')
      create_place(name: 'List place', source: 'list', context: { id: list.id.to_s })
      list.delete

      get :index
      listed = JSON.parse(response.body).find { |row| row['name'] == 'List place' }
      expect(listed['availability']['source']).to eq('missing')
      expect(listed['source_label']).to be_nil
      expect(response.body).not_to include('morning-list-title-xyz')

      group = Fabricate(:account, actor_type: 'Group', username: 'hidden_group_user', display_name: 'secret-group-label')
      secret = Fabricate(:status, account: user.account, visibility: :public, text: 'secret-status-body')
      create_place(name: 'Group place', source: 'group', context: { id: group.id.to_s }, anchor: anchor(secret.id.to_s))
      expect(response).to have_http_status(201)
      expect(response.body).not_to include('secret-group-label')
      expect(response.body).not_to include('secret-status-body')

      group.block!(user.account)
      get :index
      blocked = JSON.parse(response.body).find { |row| row['name'] == 'Group place' }
      expect(blocked['availability']['source']).to eq('not_accessible')
      expect(blocked['availability']['anchor']).to eq('unchecked')
      expect(blocked['source_label']).to be_nil
      expect(response.body).not_to include('secret-group-label')
      expect(response.body).not_to include('secret-status-body')
      expect(response.body).not_to include('hidden_group_user')
    end
  end

  describe 'PATCH #update and DELETE #destroy' do
    it 'renames with the lock version and refuses a stale write' do
      create_place
      id = JSON.parse(response.body)['id']

      patch :update, params: { id: id, name: 'Later', lock_version: 0 }
      expect(response).to have_http_status(200)
      expect(JSON.parse(response.body)['name']).to eq('Later')
      expect(JSON.parse(response.body)['lock_version']).to eq(1)

      patch :update, params: { id: id, name: 'Stale', lock_version: 0 }
      expect(response).to have_http_status(409)
      expect(JSON.parse(response.body)['error']).to eq('conflict')
      expect(user.timeline_reading_bookmarks.find(id).name).to eq('Later')
    end

    it 'deletes only the owner row' do
      create_place(name: 'Gone')
      id = JSON.parse(response.body)['id']

      delete :destroy, params: { id: id }
      expect(response).to have_http_status(200)
      expect(user.timeline_reading_bookmarks).to be_empty
    end
  end

  describe 'GET #capabilities' do
    it 'describes retention and closed sources' do
      get :capabilities
      body = JSON.parse(response.body)

      expect(response).to have_http_status(200)
      expect(body['per_user_limit']).to eq(50)
      expect(body['retention']['redis_max_items']).to eq(2000)
      expect(body['sources']['home']['capability']).to eq('approximate')
      expect(body['sources']['home']['privacy']).to eq('account')
      expect(body['sources']['list']['privacy']).to eq('owner_list')
      expect(body['closed_sources']).to include('direct')
      expect(body['rejects']).to include('status_text', 'search_text', 'window')
    end
  end

  it 'has no column for status text' do
    expect(TimelineReadingBookmark.column_names).not_to include('text', 'body', 'query', 'statuses', 'spoiler_text')
  end
end
