# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Standard tag follow cutover' do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'read:follows write:follows' }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:writer) { HashtagUnification::TagFollowDeliveryWriter.new }

  def stub_follow_tag_mirror
    allow(HashtagUnification::FollowTagMirror).to receive(:new)
      .and_raise('U3a mirror must not run for canonical standard tag writes')
  end

  def expect_parity_ok
    result = HashtagUnification::FollowTagParity.new.call
    expect(result[:ok]).to eq(true), result.inspect
    expect(result[:management_ready]).to eq(true), result.inspect
  end

  it 'exposes a standard-follow Home destination through GET /api/v1/follow_tags' do
    stub_follow_tag_mirror

    post '/api/v1/tags/u3b3exsurface/follow', headers: headers
    expect(response).to have_http_status(200)
    expect(body_as_json[:following]).to be true

    home = TagFollowDelivery.for_account(user.account).home.first
    get '/api/v1/follow_tags', headers: headers
    listed = body_as_json

    expect(listed).to contain_exactly(
      a_hash_including(id: home.legacy_follow_tag_id.to_s, name: 'u3b3exsurface')
    )
    expect(listed.first[:id]).not_to eq home.id.to_s
    expect_parity_ok

    post '/api/v1/tags/u3b3exsurface/unfollow', headers: headers
    expect(response).to have_http_status(200)
    expect(body_as_json[:following]).to be false

    get '/api/v1/follow_tags', headers: headers
    expect(body_as_json).to eq([])
    expect(TagFollow.where(account: user.account)).to be_empty
    expect_parity_ok
  end

  it 'keeps a compatibility-API Home destination visible after idempotent standard follow' do
    stub_follow_tag_mirror
    post '/api/v1/follow_tags', headers: headers, params: { name: 'u3b3eapicross' }
    created = body_as_json
    expect(response).to have_http_status(200)

    post '/api/v1/tags/u3b3eapicross/follow', headers: headers
    expect(response).to have_http_status(200)
    expect(body_as_json[:following]).to be true

    get '/api/v1/follow_tags', headers: headers
    expect(body_as_json).to contain_exactly(a_hash_including(id: created[:id], name: 'u3b3eapicross'))
    expect_parity_ok
  end

  it 'lets a Settings-writer List destination participate in standard follow' do
    stub_follow_tag_mirror
    list = Fabricate(:list, account: user.account, title: 'A')
    listed = writer.create!(account: user.account, name: 'u3b3esetcross', list: list, media_only: true)

    post '/api/v1/tags/u3b3esetcross/follow', headers: headers
    expect(response).to have_http_status(200)

    get '/api/v1/follow_tags', headers: headers
    ids = body_as_json.map { |row| row[:id] }
    home = TagFollow.find_by!(account: user.account, tag: listed.tag).deliveries.home.first
    expect(ids).to include(listed.legacy_follow_tag_id.to_s)
    expect(ids).to include(home.legacy_follow_tag_id.to_s)
    expect_parity_ok
  end
end
