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

  it 'gives an unauthorized viewer the same response for a hidden boost and no boost' do
    lookup(booster.id)
    absent_body = body_as_json

    Fabricate(:status, account: booster, reblog: original, text: '', visibility: :private)
    lookup(booster.id)
    hidden_body = body_as_json

    hidden = Status.where(account: booster, reblog_of_id: original.id).first
    duplicate = hidden.dup
    duplicate.id = nil
    duplicate.uri = "#{hidden.uri}/hidden"
    duplicate.visibility = :private
    duplicate.save!(validate: false)
    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(hidden_body).to eq absent_body
    expect(body_as_json).to eq absent_body
    expect(body_as_json[:state]).to eq 'absent'
    expect(body_as_json[:id]).to be_nil
    expect(body_as_json.to_s).not_to include('unavailable')
  end

  it 'stays ambiguous when a newer hidden wrapper sits beside two visible ones' do
    first = Fabricate(:status, account: booster, reblog: original, text: '')
    second = first.dup
    second.id = nil
    second.uri = "#{first.uri}/other"
    second.save!(validate: false)
    hidden = first.dup
    hidden.id = nil
    hidden.uri = "#{first.uri}/hidden"
    hidden.visibility = :private
    hidden.save!(validate: false)

    lookup(booster.id)

    expect(body_as_json[:state]).to eq 'unknown'
    expect(body_as_json[:reason]).to eq 'ambiguous'
    expect(body_as_json[:id]).to be_nil
  end

  it 'does not change the response when nine newer hidden wrappers are added beside one visible boost' do
    visible = Fabricate(:status, account: booster, reblog: original, text: '')

    lookup(booster.id)
    alone = body_as_json

    add_hidden_wrappers(visible, 9)
    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json).to eq alone
    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq visible.id.to_s
    expect(body_as_json[:reason]).to be_nil
  end

  it 'stays ambiguous when nine newer hidden wrappers precede two visible boosts' do
    first = Fabricate(:status, account: booster, reblog: original, text: '')
    duplicate_wrapper(first, 'other', visibility: :public)
    add_hidden_wrappers(first, 9)

    lookup(booster.id)

    expect(response).to have_http_status(200)
    expect(body_as_json[:state]).to eq 'unknown'
    expect(body_as_json[:reason]).to eq 'ambiguous'
    expect(body_as_json[:id]).to be_nil
  end

  it 'keeps a follower-visible private boost when newer direct wrappers are added' do
    viewer.account.follow!(booster)
    visible = Fabricate(:status, account: booster, reblog: original, text: '', visibility: :private)

    lookup(booster.id)
    alone = body_as_json

    add_hidden_wrappers(visible, 9, visibility: :direct)
    lookup(booster.id)

    expect(body_as_json).to eq alone
    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq visible.id.to_s
  end

  it 'gives a blocked viewer the same response as no boost' do
    lookup(booster.id)
    absent_body = body_as_json

    Fabricate(:status, account: booster, reblog: original, text: '')
    booster.block!(viewer.account)
    lookup(booster.id)

    expect(body_as_json).to eq absent_body
    expect(body_as_json[:state]).to eq 'absent'
    expect(body_as_json[:id]).to be_nil
  end

  it 'still resolves a public boost when the viewer blocks the booster' do
    wrapper = Fabricate(:status, account: booster, reblog: original, text: '')
    viewer.account.block!(booster)

    lookup(booster.id)

    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq wrapper.id.to_s
  end

  it 'resolves a direct boost that mentions the viewer when newer personal wrappers are added' do
    visible = Fabricate(:status, account: booster, reblog: original, text: '')
    visible.update_columns(visibility: Status.visibilities.fetch('direct'))
    Fabricate(:mention, account: viewer.account, status: visible)

    lookup(booster.id)
    alone = body_as_json

    add_hidden_wrappers(visible, 9, visibility: :personal)
    lookup(booster.id)

    expect(body_as_json).to eq alone
    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq visible.id.to_s
  end

  it 'resolves an expired public boost only after the viewer has favourited the original' do
    wrapper = Fabricate(:status, account: booster, reblog: original, text: '')
    wrapper.update_columns(expired_at: 1.hour.ago)

    lookup(booster.id)
    expect(body_as_json[:state]).to eq 'absent'
    expect(body_as_json[:id]).to be_nil

    Fabricate(:favourite, account: viewer.account, status: original)
    add_hidden_wrappers(wrapper, 9)
    lookup(booster.id)

    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq wrapper.id.to_s
    expect(body_as_json[:reason]).to be_nil
  end

  it 'counts only visible wrappers when deciding a boost is ambiguous' do
    visible = Fabricate(:status, account: booster, reblog: original, text: '')
    hidden = visible.dup
    hidden.id = nil
    hidden.uri = "#{visible.uri}/hidden"
    hidden.visibility = :private
    hidden.save!(validate: false)

    lookup(booster.id)

    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq visible.id.to_s
    expect(body_as_json[:id]).not_to eq hidden.id.to_s
  end

  it 'returns a private boost to the account that posted it' do
    wrapper = Fabricate(:status, account: viewer.account, reblog: original, text: '', visibility: :private)

    lookup(viewer.account.id)

    expect(body_as_json[:state]).to eq 'resolved'
    expect(body_as_json[:id]).to eq wrapper.id.to_s
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

  def duplicate_wrapper(status, suffix, visibility: status.visibility)
    copy = status.dup
    copy.id = nil
    copy.uri = "#{status.uri}/#{suffix}"
    copy.visibility = visibility
    copy.save!(validate: false)
    copy
  end

  def add_hidden_wrappers(status, count, visibility: :private)
    count.times do |index|
      duplicate_wrapper(status, "hidden-#{visibility}-#{index}", visibility: visibility)
    end
  end
end
