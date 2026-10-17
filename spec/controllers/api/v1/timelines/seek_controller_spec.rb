# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Timelines::SeekController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses read:lists') }
  let(:author) { Fabricate(:user).account }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def post_seek(extra)
    post :create, params: {
      version: 1,
      preference: 'nearest',
      context: { only_media: false, without_media: false, without_bot: false },
    }.deep_merge(extra)
  end

  it 'returns a public status id as a string' do
    status = Fabricate(:status, account: author, visibility: :public)
    post_seek(source: 'public', kind: 'status', seek_target: { id: status.id.to_s })

    body = JSON.parse(response.body)
    expect(response).to have_http_status(200)
    expect(body['outcome']).to eq('resolved')
    expect(body['anchor_id']).to eq(status.id.to_s)
    expect(response.body).to include(%("#{status.id}"))
  end

  it 'does not leak a direct status through the body or a found anchor' do
    status = Fabricate(:status, account: author, visibility: :direct, text: 'direct-leak-phrase')
    post_seek(source: 'public', kind: 'status', seek_target: { id: status.id.to_s })

    expect(response).to have_http_status(200)
    expect(response.body).not_to include('direct-leak-phrase')
    expect(JSON.parse(response.body)['outcome']).to eq('not_found')
    expect(JSON.parse(response.body)).not_to have_key('anchor_id')
  end

  it 'requires a user for home' do
    allow(controller).to receive(:doorkeeper_token) { nil }
    post_seek(source: 'home', kind: 'status', seek_target: { id: '1' })

    expect(response).to have_http_status(422)
  end

  it 'does not disclose another account list' do
    list = Fabricate(:list, account: author)
    status = Fabricate(:status, account: author, text: 'foreign-list-secret')
    post_seek(source: 'list', kind: 'status', context: { id: list.id.to_s }, seek_target: { id: status.id.to_s })

    expect(response).to have_http_status(404)
    expect(response.body).not_to include('foreign-list-secret')
  end

  it 'does not disclose another account list for date or account probes' do
    list = Fabricate(:list, account: author)
    status = Fabricate(:status, account: author, text: 'foreign-list-date-secret')

    post_seek(source: 'list', kind: 'date', context: { id: list.id.to_s }, seek_target: { at: status.created_at.iso8601 })
    expect(response).to have_http_status(404)
    expect(response.body).not_to include('foreign-list-date-secret')

    post_seek(source: 'list', kind: 'account', context: { id: list.id.to_s }, seek_target: { account_id: author.id.to_s })
    expect(response).to have_http_status(404)
    expect(response.body).not_to include('foreign-list-date-secret')
  end

  it 'does not treat a user account as a group source' do
    status = Fabricate(:status, account: author, visibility: :public, text: 'not-a-group-body')

    post_seek(source: 'group', kind: 'status', context: { id: author.id.to_s }, seek_target: { id: status.id.to_s })

    expect(response).to have_http_status(404)
    expect(response.body).not_to include('not-a-group-body')
  end

  it 'rejects search text in the target' do
    post :create, params: {
      version: 1,
      source: 'public',
      kind: 'searchHit',
      preference: 'nearest',
      seek_target: { id: '10', text: 'hidden query' },
    }

    body = JSON.parse(response.body)
    expect(body['outcome']).to eq('unsupported')
    expect(body['reason']).to eq('search_text_not_accepted')
    expect(response.body).not_to include('hidden query')
  end
end
