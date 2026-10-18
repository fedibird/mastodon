# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account context reblog wrapper lookup', type: :request do
  let(:viewer) { Fabricate(:user, account: Fabricate(:account, username: 'viewer')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: viewer.id, scopes: 'read:statuses') }
  let(:booster) { Fabricate(:account, username: 'booster') }
  let(:author) { Fabricate(:account, username: 'author') }
  let(:original) { Fabricate(:status, account: author, visibility: :public) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def lookup(account_id, status_id = original.id)
    get "/api/v1/statuses/#{status_id}/reblog_wrapper", params: { account_id: account_id }, headers: headers
  end

  it 'returns the wrapper id for that account and not the original id' do
    wrapper = Fabricate(:status, account: booster, reblog: original, text: '')

    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq wrapper.id.to_s
    expect(body_as_json[:id]).not_to eq original.id.to_s
    expect(body_as_json[:account_id]).to eq booster.id.to_s
  end

  it 'reports absent when that account has no boost' do
    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'absent'
    expect(body_as_json[:id]).to be_nil
  end

  it 'reports unknown when the account is not in the database' do
    lookup('999999999999999999')

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'unknown'
    expect(body_as_json[:reason]).to eq 'account_unknown'
    expect(body_as_json[:id]).to be_nil
  end

  it 'reports unknown instead of choosing when two wrappers exist' do
    first = Fabricate(:status, account: booster, reblog: original, text: '')
    duplicate = first.dup
    duplicate.id = nil
    duplicate.uri = "#{first.uri}/other"
    duplicate.save!(validate: false)

    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'unknown'
    expect(body_as_json[:reason]).to eq 'ambiguous'
    expect(body_as_json[:id]).to be_nil
  end

  it 'reports unavailable when the wrapper is not visible' do
    Fabricate(:status, account: booster, reblog: original, text: '', visibility: :private)

    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'unavailable'
    expect(body_as_json[:id]).to be_nil
  end

  it 'does not reveal a wrapper of a status the viewer cannot see' do
    hidden = Fabricate(:status, account: author, visibility: :private)
    Fabricate(:status, account: booster, reblog: hidden, text: '', visibility: :private)

    lookup(booster.id, hidden.id)

    expect(response).to have_http_status(404)
  end

  it 'keeps a discarded boost absent' do
    wrapper = Fabricate(:status, account: booster, reblog: original, text: '')
    wrapper.discard

    lookup(booster.id)

    expect(body_as_json[:state]).to eq 'absent'
    expect(body_as_json[:id]).to be_nil
  end
end
