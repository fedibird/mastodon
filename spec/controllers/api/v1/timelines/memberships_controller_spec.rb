# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Timelines::MembershipsController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses read:lists') }
  let(:author) { Fabricate(:user).account }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def post_membership(extra)
    post :create, params: {
      version: 1,
      source: 'public',
      context: { only_media: false, without_media: false, without_bot: false },
      ids: [],
    }.deep_merge(extra)
  end

  it 'returns confirmed public ids as strings and omits bodies' do
    status = Fabricate(:status, account: author, visibility: :public, text: 'visible-but-not-in-json')
    post_membership(ids: [status.id.to_s])

    body = JSON.parse(response.body)
    expect(response).to have_http_status(200)
    expect(body['outcome']).to eq('complete')
    expect(body['members']).to eq([status.id.to_s])
    expect(body['results'].first.keys).to contain_exactly('id', 'outcome')
    expect(response.body).to include(%("#{status.id}"))
    expect(response.body).not_to include('visible-but-not-in-json')
  end

  it 'does not leak a direct status' do
    status = Fabricate(:status, account: author, visibility: :direct, text: 'direct-leak-phrase')
    post_membership(ids: [status.id.to_s])

    body = JSON.parse(response.body)
    expect(body['results'].first['outcome']).to eq('not_found')
    expect(body['members']).to eq([])
    expect(response.body).not_to include('direct-leak-phrase')
    expect(body['results'].first.keys).to contain_exactly('id', 'outcome')
  end

  it 'requires a user for home' do
    allow(controller).to receive(:doorkeeper_token) { nil }
    post_membership(source: 'home', ids: ['1'])

    expect(response).to have_http_status(422)
  end

  it 'does not disclose another account list or a user id used as a group' do
    list = Fabricate(:list, account: author)
    status = Fabricate(:status, account: author, text: 'foreign-list-secret')
    post_membership(source: 'list', context: { id: list.id.to_s }, ids: [status.id.to_s])

    expect(response).to have_http_status(404)
    expect(response.body).not_to include('foreign-list-secret')

    post_membership(source: 'group', context: { id: author.id.to_s }, ids: [status.id.to_s])
    expect(response).to have_http_status(404)
    expect(response.body).not_to include('foreign-list-secret')
  end

  it 'rejects search text and redacts ids and query keys in logs' do
    post :create, params: {
      version: 1,
      source: 'public',
      kind: 'searchHit',
      ids: ['10'],
      text: 'hidden query',
    }

    body = JSON.parse(response.body)
    expect(body['outcome']).to eq('unsupported')
    expect(body['reason']).to eq('search_text_not_accepted')
    expect(body).not_to have_key('results')
    expect(response.body).not_to include('hidden query')

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('ids' => ['10'], 'q' => 'secret', 'text' => 'secret', 'spoiler_text' => 'kept', 'status' => 'kept')
    expect(filtered['ids']).to eq('[FILTERED]')
    expect(filtered['q']).to eq('[FILTERED]')
    expect(filtered['text']).to eq('[FILTERED]')
    expect(filtered['spoiler_text']).to eq('kept')
    expect(filtered['status']).to eq('kept')
  end
end
