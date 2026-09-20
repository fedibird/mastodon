# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TagsController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:follows') }
  let(:tag)   { Fabricate(:tag, name: 'u3b1bridge') }

  before { allow(controller).to receive(:doorkeeper_token) { token } }

  it 'follows through legacy FollowTag and reports following from TagFollow' do
    post :follow, params: { id: tag.name }
    body = body_as_json

    expect(response).to have_http_status(200)
    expect(FollowTag.exists?(account: user.account, tag: tag, list_id: nil)).to be true
    expect(TagFollow.exists?(account: user.account, tag: tag)).to be true
    expect(body[:following]).to be true
  end

  it 'unfollows a Home-only relation through the U3a mirror' do
    FollowTag.create!(account: user.account, tag: tag)

    post :unfollow, params: { id: tag.name }
    body = body_as_json

    expect(response).to have_http_status(200)
    expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    expect(TagFollow.where(account: user.account, tag: tag)).to be_empty
    expect(body[:following]).to be false
  end
end
