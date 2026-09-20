# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:follows') }
  let(:tag)   { Fabricate(:tag, name: 'u3b3etag') }
  let(:writer) { HashtagUnification::TagFollowDeliveryWriter.new }

  before { allow(controller).to receive(:doorkeeper_token) { token } }

  def stub_follow_tag_mirror
    allow(HashtagUnification::FollowTagMirror).to receive(:new)
      .and_raise('U3a mirror must not run for canonical standard tag writes')
  end

  def unused_legacy_id
    [
      FollowTag.maximum(:id) || 0,
      TagFollowDelivery.maximum(:id) || 0,
    ].max + 1_000_000
  end

  describe 'POST #follow' do
    it 'creates a canonical Home relation and reports following: true' do
      stub_follow_tag_mirror

      post :follow, params: { id: tag.name }
      body = body_as_json
      tag_follow = TagFollow.find_by!(account: user.account, tag: tag)
      home = tag_follow.deliveries.home.first

      expect(response).to have_http_status(200)
      expect(body[:following]).to be true
      expect(body[:name]).to eq 'u3b3etag'
      expect(tag_follow.deliveries.count).to eq 1
      expect(home.list_id).to be_nil
      expect(FollowTag.find(home.legacy_follow_tag_id).tag_id).to eq tag.id
      expect(response.headers['X-RateLimit-Limit']).to eq RateLimiter::FAMILIES[:follows][:limit].to_s
      expect(response.headers['X-RateLimit-Remaining']).to eq (RateLimiter::FAMILIES[:follows][:limit] - 1).to_s
    end

    it 'persists a brand-new valid hashtag and reports following: true' do
      stub_follow_tag_mirror
      expect(Tag.find_normalized('u3b3ebrandnew')).to be_nil

      post :follow, params: { id: 'u3b3ebrandnew' }
      persisted = Tag.find_normalized('u3b3ebrandnew')

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be true
      expect(body_as_json[:name]).to eq 'u3b3ebrandnew'
      expect(persisted).to be_present
      expect(TagFollow.exists?(account: user.account, tag: persisted)).to be true
    end

    it 'is HTTP 200 and creates no duplicate rows when Home already exists' do
      stub_follow_tag_mirror
      post :follow, params: { id: tag.name }
      home_id = TagFollow.find_by!(account: user.account, tag: tag).deliveries.home.first.id

      post :follow, params: { id: tag.name }

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be true
      expect(TagFollow.where(account: user.account, tag: tag).count).to eq 1
      expect(TagFollowDelivery.for_account(user.account).for_tags(tag).count).to eq 1
      expect(TagFollow.find_by!(account: user.account, tag: tag).deliveries.home.first.id).to eq home_id
      expect(FollowTag.where(account: user.account, tag: tag).count).to eq 1
    end

    it 'adds Home to a Lists-only relation without deleting Lists' do
      stub_follow_tag_mirror
      list_a = Fabricate(:list, account: user.account, title: 'A')
      list_b = Fabricate(:list, account: user.account, title: 'B')
      listed_a = writer.create!(account: user.account, name: tag.name, list: list_a, media_only: true)
      listed_b = writer.create!(account: user.account, name: tag.name, list: list_b, media_only: false)

      post :follow, params: { id: tag.name }
      tag_follow = TagFollow.find_by!(account: user.account, tag: tag)

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be true
      expect(tag_follow.deliveries.home.count).to eq 1
      expect(tag_follow.deliveries.list.map(&:id)).to contain_exactly(listed_a.id, listed_b.id)
      expect(listed_a.reload.media_only).to be true
      expect(listed_b.reload.media_only).to be false
      expect(response.headers['X-RateLimit-Remaining']).to eq RateLimiter::FAMILIES[:follows][:limit].to_s
    end

    it 'returns 422 and does not add Home when the rollback shadow is inconsistent' do
      list = Fabricate(:list, account: user.account, title: 'A')
      tag_follow = TagFollow.create!(account: user.account, tag: tag)
      TagFollowDelivery.create!(
        tag_follow: tag_follow,
        list: list,
        legacy_follow_tag_id: unused_legacy_id
      )

      post :follow, params: { id: tag.name }

      expect(response).to have_http_status(422)
      expect(tag_follow.deliveries.home).to be_empty
      expect(TagFollow.where(id: tag_follow.id)).to exist
    end
  end

  describe 'POST #unfollow' do
    it 'removes a Home-only relation and reports following: false' do
      stub_follow_tag_mirror
      writer.standard_follow!(account: user.account, tag: tag)

      post :unfollow, params: { id: tag.name }

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be false
      expect(TagFollow.where(account: user.account, tag: tag)).to be_empty
      expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    end

    it 'removes Home and every List destination together' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')
      writer.create!(account: user.account, name: tag.name)
      writer.create!(account: user.account, name: tag.name, list: list, media_only: true)

      post :unfollow, params: { id: tag.name }

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be false
      expect(TagFollow.where(account: user.account, tag: tag)).to be_empty
      expect(TagFollowDelivery.for_account(user.account).for_tags(tag)).to be_empty
      expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    end

    it 'is HTTP 200 with no mutation when already unfollowed' do
      post :unfollow, params: { id: tag.name }

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be false
      expect(TagFollow.where(account: user.account, tag: tag)).to be_empty
    end

    it 'returns 422 and keeps the relation when the rollback shadow is missing' do
      home = writer.create!(account: user.account, name: tag.name)
      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).delete_all

      post :unfollow, params: { id: tag.name }

      expect(response).to have_http_status(422)
      expect(TagFollowDelivery.where(id: home.id)).to exist
      expect(TagFollow.exists?(account: user.account, tag: tag)).to be true
    end
  end
end
