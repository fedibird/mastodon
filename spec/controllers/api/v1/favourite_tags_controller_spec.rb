# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::FavouriteTagsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write') }

  before { allow(controller).to receive(:doorkeeper_token) { token } }

  describe 'POST #create' do
    it 'creates a favourite tag' do
      post :create, params: { name: 'fedibird' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq 'fedibird'
      expect(user.account.favourite_tags.count).to eq 1
    end

    it 'returns the existing favourite tag instead of creating a duplicate' do
      tag = Fabricate(:tag, name: 'CaseTag')
      existing = Fabricate(:favourite_tag, account: user.account, tag: tag)

      post :create, params: { name: '#casetag' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq existing.id.to_s
      expect(user.account.favourite_tags.count).to eq 1
    end

    it 'treats NFKC-equivalent names as the same favourite tag' do
      tag = Fabricate(:tag, name: 'Ａ')
      existing = Fabricate(:favourite_tag, account: user.account, tag: tag)

      post :create, params: { name: 'A' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq existing.id.to_s
      expect(user.account.favourite_tags.count).to eq 1
    end

    it 'keeps the favourite tag limit for a new tag' do
      FavouriteTag::LIMIT.times do |index|
        Fabricate(:favourite_tag, account: user.account, tag: Fabricate(:tag, name: "kept#{index}"))
      end

      post :create, params: { name: 'overflow' }

      expect(response).to have_http_status(422)
      expect(user.account.favourite_tags.count).to eq FavouriteTag::LIMIT
    end
  end
end
