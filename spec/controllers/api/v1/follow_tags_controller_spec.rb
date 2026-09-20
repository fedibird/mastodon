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

  def stub_follow_tag_mirror
    allow(HashtagUnification::FollowTagMirror).to receive(:new)
      .and_raise('U3a mirror must not run for canonical API writes')
  end

  def expect_parity_ok
    result = HashtagUnification::FollowTagParity.new.call
    expect(result[:ok]).to eq(true), result.inspect
    expect(result[:management_ready]).to eq(true), result.inspect
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

  describe 'canonical write path' do # rubocop:disable Metrics/BlockLength
    it 'creates through TagFollowDelivery and keeps a FollowTag shadow with the same ID' do
      stub_follow_tag_mirror

      post :create, params: { name: 'u3b3ccreate', media_only: true }
      created = body_as_json
      delivery = TagFollowDelivery.find_by!(legacy_follow_tag_id: created[:id])
      shadow = FollowTag.find(created[:id])
      canonical_time = 2.days.from_now.change(usec: 0)
      delivery.update_columns(updated_at: canonical_time)

      get :show, params: { id: created[:id] }

      expect(response).to have_http_status(200)
      expect(created[:id]).to eq shadow.id.to_s
      expect(created[:id]).not_to eq delivery.id.to_s
      expect(created[:name]).to eq 'u3b3ccreate'
      expect(delivery.media_only).to be true
      expect(shadow.media_only).to be true
      expect(body_as_json[:id]).to eq shadow.id.to_s
      expect(Time.zone.parse(body_as_json[:updated_at])).to be_within(1.second).of(canonical_time)
      expect_parity_ok
    end

    it 'rejects a duplicate Home create' do
      stub_follow_tag_mirror
      post :create, params: { name: 'u3b3cdup' }

      expect { post :create, params: { name: 'u3b3cdup' } }.not_to change(TagFollowDelivery, :count)
      expect(response).to have_http_status(422)
      expect_parity_ok
    end

    it 'updates a canonical resource without FollowTag callbacks' do
      stub_follow_tag_mirror
      post :create, params: { name: 'u3b3cold' }
      compatibility_id = body_as_json[:id]

      put :update, params: { id: compatibility_id, name: 'u3b3cnew', media_only: true }
      get :show, params: { id: compatibility_id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq compatibility_id
      expect(body_as_json[:name]).to eq 'u3b3cnew'
      expect(TagFollowDelivery.find_by!(legacy_follow_tag_id: compatibility_id).media_only).to be true
      expect(FollowTag.find(compatibility_id).media_only).to be true
      expect_parity_ok
    end

    it 'destroys a canonical resource and its shadow' do
      stub_follow_tag_mirror
      post :create, params: { name: 'u3b3cdel' }
      compatibility_id = body_as_json[:id]

      delete :destroy, params: { id: compatibility_id }
      get :show, params: { id: compatibility_id }

      expect(FollowTag.where(id: compatibility_id)).to be_empty
      expect(TagFollowDelivery.where(legacy_follow_tag_id: compatibility_id)).to be_empty
      expect(response).to have_http_status(404)
      expect_parity_ok
    end

    it 'updates a legacy-created row through the canonical writer' do
      source = FollowTag.create!(account: user.account, tag: Fabricate(:tag, name: 'u3b3cbridge'))
      stub_follow_tag_mirror

      put :update, params: { id: source.id, name: 'u3b3cbridged' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq source.id.to_s
      expect(body_as_json[:name]).to eq 'u3b3cbridged'
      expect(FollowTag.find(source.id).tag.name).to eq 'u3b3cbridged'
      expect_parity_ok
    end

    it 'does not update or destroy another account\'s compatibility ID' do
      source = FollowTag.create!(account: other.account, tag: Fabricate(:tag, name: 'u3b3ciso'))

      put :update, params: { id: source.id, name: 'nope' }
      expect(response).to have_http_status(404)

      delete :destroy, params: { id: source.id }
      expect(response).to have_http_status(404)
      expect(FollowTag.where(id: source.id)).to exist
    end

    it 'fails closed when the rollback shadow is missing' do
      tag = Fabricate(:tag, name: 'u3b3cnoshadow')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      put :update, params: { id: delivery.legacy_follow_tag_id, media_only: true }
      expect(response).to have_http_status(422)
      expect(delivery.reload.media_only).to be false

      delete :destroy, params: { id: delivery.legacy_follow_tag_id }
      expect(response).to have_http_status(422)
      expect(TagFollowDelivery.where(id: delivery.id)).to exist
    end
  end
end
