# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::FollowTagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bob')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:follows write:follows' }

  before { allow(controller).to receive(:doorkeeper_token) { token } }

  def unused_legacy_id
    [
      FollowTag.maximum(:id) || 0,
      TagFollowDelivery.maximum(:id) || 0,
    ].max + 1_000_000
  end

  def insert_legacy_follow_tag(account:, tag:)
    now = Time.now.utc
    FollowTag.insert_all!(
      [
        {
          account_id: account.id,
          tag_id: tag.id,
          list_id: nil,
          media_only: false,
          created_at: now,
          updated_at: now,
        },
      ]
    )
    FollowTag.find_by!(account: account, tag: tag)
  end

  def create_canonical_delivery(account:, tag:, list: nil, legacy_id: unused_legacy_id)
    tag_follow = TagFollow.find_or_create_by!(account: account, tag: tag)
    TagFollowDelivery.create!(tag_follow: tag_follow, list: list, legacy_follow_tag_id: legacy_id)
  end

  describe 'GET #index' do
    it 'includes a canonical-only delivery and uses the compatibility ID' do
      tag = Fabricate(:tag, name: 'u3b3bindex')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json).to contain_exactly(
        a_hash_including(id: delivery.legacy_follow_tag_id.to_s, name: 'u3b3bindex')
      )
      expect(body_as_json.first[:id]).not_to eq delivery.id.to_s
      expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    end

    it 'does not list a callback-bypassing FollowTag without TagFollowDelivery' do
      tag = Fabricate(:tag, name: 'u3b3blegacyonly')
      insert_legacy_follow_tag(account: user.account, tag: tag)

      get :index

      expect(FollowTag.exists?(account: user.account, tag: tag)).to be true
      expect(body_as_json).to eq([])
    end

    it 'does not list another account\'s canonical delivery' do
      tag = Fabricate(:tag, name: 'u3b3bother')
      create_canonical_delivery(account: other.account, tag: tag)

      get :index

      expect(body_as_json).to eq([])
    end
  end

  describe 'GET #show' do
    it 'reads a canonical-only delivery by legacy_follow_tag_id' do
      tag = Fabricate(:tag, name: 'u3b3bshow')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      get :show, params: { id: delivery.legacy_follow_tag_id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq delivery.legacy_follow_tag_id.to_s
      expect(body_as_json[:name]).to eq 'u3b3bshow'
    end

    it 'does not resolve a canonical PK that differs from the compatibility ID' do
      tag = Fabricate(:tag, name: 'u3b3bpk')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      expect(delivery.id).not_to eq delivery.legacy_follow_tag_id

      get :show, params: { id: delivery.id }

      expect(response).to have_http_status(404)
    end

    it 'returns not found for a callback-bypassing FollowTag without TagFollowDelivery' do
      tag = Fabricate(:tag, name: 'u3b3bshownone')
      source = insert_legacy_follow_tag(account: user.account, tag: tag)

      get :show, params: { id: source.id }

      expect(response).to have_http_status(404)
    end

    it 'does not show another account\'s delivery by compatibility ID' do
      tag = Fabricate(:tag, name: 'u3b3bforeign')
      delivery = create_canonical_delivery(account: other.account, tag: tag)

      get :show, params: { id: delivery.legacy_follow_tag_id }

      expect(response).to have_http_status(404)
    end
  end

  describe 'write/read bridge' do
    it 'creates through FollowTag and shows the mirrored canonical delivery' do
      post :create, params: { name: 'u3b3bcreate' }
      created = body_as_json
      source = FollowTag.find(created[:id])
      delivery = TagFollowDelivery.find_by!(legacy_follow_tag_id: source.id)
      canonical_time = 2.days.from_now.change(usec: 0)
      delivery.update_columns(updated_at: canonical_time)

      get :show, params: { id: created[:id] }

      expect(created[:id]).to eq source.id.to_s
      expect(created[:name]).to eq 'u3b3bcreate'
      expect(delivery.legacy_follow_tag_id).to eq source.id
      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq source.id.to_s
      expect(body_as_json[:name]).to eq 'u3b3bcreate'
      expect(Time.zone.parse(body_as_json[:updated_at])).to be_within(1.second).of(canonical_time)
    end

    it 'updates the legacy write path and keeps the same compatibility ID' do
      source = FollowTag.create!(account: user.account, tag: Fabricate(:tag, name: 'u3b3bold'))

      put :update, params: { id: source.id, name: 'u3b3bnew' }
      get :show, params: { id: source.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq source.id.to_s
      expect(body_as_json[:name]).to eq 'u3b3bnew'
      expect(TagFollowDelivery.find_by!(legacy_follow_tag_id: source.id).name).to eq 'u3b3bnew'
    end

    it 'destroys the legacy write path and hides the canonical read resource' do
      source = FollowTag.create!(account: user.account, tag: Fabricate(:tag, name: 'u3b3bdel'))

      delete :destroy, params: { id: source.id }
      get :show, params: { id: source.id }

      expect(FollowTag.where(id: source.id)).to be_empty
      expect(TagFollowDelivery.where(legacy_follow_tag_id: source.id)).to be_empty
      expect(response).to have_http_status(404)
    end
  end
end
