# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::FollowedTagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:follows') }

  before { allow(controller).to receive(:doorkeeper_token) { token } }

  def names_from_body
    body_as_json.map { |tag| tag[:name] }
  end

  describe 'GET #index' do # rubocop:disable Metrics/BlockLength
    it 'includes a TagFollow-only relation and reports following' do
      tag = Fabricate(:tag, name: 'u3b1targetonly')
      TagFollow.create!(account: user.account, tag: tag)

      get :index

      expect(response).to have_http_status(200)
      expect(names_from_body).to contain_exactly('u3b1targetonly')
      expect(body_as_json.first[:following]).to be true
      expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    end

    it 'includes a List-only follow once and reports following' do
      tag = Fabricate(:tag, name: 'u3b1listonly')
      list = Fabricate(:list, account: user.account, title: 'A')
      FollowTag.create!(account: user.account, tag: tag, list: list)
      target = TagFollow.find_by!(account: user.account, tag: tag)

      get :index

      expect(target.deliveries.home).to be_empty
      expect(target.deliveries.list.count).to eq 1
      expect(names_from_body).to contain_exactly('u3b1listonly')
      expect(body_as_json.first[:following]).to be true
    end

    it 'returns a multi-destination follow once' do
      tag = Fabricate(:tag, name: 'u3b1multi')
      list = Fabricate(:list, account: user.account, title: 'A')
      FollowTag.create!(account: user.account, tag: tag)
      FollowTag.create!(account: user.account, tag: tag, list: list)
      target = TagFollow.find_by!(account: user.account, tag: tag)

      get :index

      expect(TagFollow.where(account: user.account, tag: tag).count).to eq 1
      expect(target.deliveries.count).to eq 2
      expect(names_from_body).to contain_exactly('u3b1multi')
    end

    it 'paginates over TagFollow ids' do
      older_tag = Fabricate(:tag, name: 'u3b1older')
      newer_tag = Fabricate(:tag, name: 'u3b1newer')
      older = TagFollow.create!(account: user.account, tag: older_tag)
      newer = TagFollow.create!(account: user.account, tag: newer_tag)

      get :index, params: { limit: 1 }

      expect(response).to have_http_status(200)
      expect(names_from_body).to contain_exactly('u3b1newer')
      expect(response.headers['Link'].find_link(%w(rel next)).href).to eq api_v1_followed_tags_url(limit: 1, max_id: newer.id)
      expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq api_v1_followed_tags_url(limit: 1, since_id: newer.id)

      get :index, params: { limit: 1, max_id: newer.id }

      expect(names_from_body).to contain_exactly('u3b1older')
      expect(assigns(:results).map(&:id)).to contain_exactly(older.id)
    end

    it 'does not list callback-bypassing FollowTag without TagFollow' do
      tag = Fabricate(:tag, name: 'u3b1legacyonly')
      now = Time.now.utc
      rows = [
        {
          account_id: user.account.id,
          tag_id: tag.id,
          list_id: nil,
          media_only: false,
          created_at: now,
          updated_at: now,
        },
      ]
      FollowTag.insert_all!(rows)

      get :index

      expect(FollowTag.exists?(account: user.account, tag: tag)).to be true
      expect(names_from_body).to eq([])
    end
  end
end
