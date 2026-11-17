# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::HashtagMutesController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    let(:scopes) { 'write:filters' }

    it 'creates one hide filter for every context and updates it when the tag is muted again' do
      post :create, params: { name: '＃番組', expires_in: 3.hours.to_i }

      expect(response).to have_http_status(200)
      json = body_as_json
      expect(json[:filter_action]).to eq 'hide'
      expect(json[:context]).to match_array(CustomFilter::VALID_CONTEXTS)
      expect(json[:tags].map { |tag| tag[:name] }).to eq ['番組']
      expect(Time.zone.parse(json[:expires_at])).to be_within(5.seconds).of(3.hours.from_now)

      post :create, params: { name: '番組', expires_in: 0 }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq json[:id]
      expect(body_as_json[:expires_at]).to be_nil
      expect(user.account.custom_filters.count).to eq 1
    end

    it 'does not change an existing keyword filter for the same word' do
      keyword = Fabricate(:custom_filter, account: user.account, phrase: 'spoilers', context: %w(home))
      Fabricate(:custom_filter_keyword, custom_filter: keyword, keyword: 'spoilers')

      post :create, params: { name: 'spoilers', expires_in: 300 }

      expect(response).to have_http_status(200)
      expect(keyword.reload.phrase).to eq 'spoilers'
      expect(keyword.keywords.count).to eq 1
      expect(user.account.custom_filters.count).to eq 2
    end

    it 'rejects a blank tag and an unknown duration' do
      post :create, params: { name: ' ', expires_in: 300 }
      expect(response).to have_http_status(422)

      post :create, params: { name: '番組', expires_in: 12.hours.to_i }
      expect(response).to have_http_status(422)
      expect(user.account.custom_filters).to be_empty
    end

    it 'refuses a read-only token' do
      token.update!(scopes: 'read:filters')

      post :create, params: { name: '番組' }

      expect(response).to have_http_status(403)
    end
  end

  describe 'PUT #update' do
    let(:scopes) { 'write:filters' }

    it 'changes the duration of the signed-in account only' do
      filter = HashtagMutes::UpsertService.new.call(user.account, name: '番組', expires_in: 300)
      other = Fabricate(:user)
      foreign = HashtagMutes::UpsertService.new.call(other.account, name: '番組', expires_in: 300)
      foreign_expiry = foreign.expires_at

      put :update, params: { id: filter.id, expires_in: 2.hours.to_i }

      expect(response).to have_http_status(200)
      expect(filter.reload.expires_at).to be_within(5.seconds).of(2.hours.from_now)
      expect(foreign.reload.expires_at).to be_within(1.second).of(foreign_expiry)

      put :update, params: { id: foreign.id, expires_in: 7.days.to_i }

      expect(response).to have_http_status(404)
      expect(foreign.reload.expires_at).to be_within(1.second).of(foreign_expiry)
    end

    it 'restores hide and can leave the current end time in place' do
      filter = HashtagMutes::UpsertService.new.call(user.account, name: '番組', expires_in: 2.hours.to_i)
      filter.update!(action: :warn, context: %w(home thread))
      expiry = filter.expires_at
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: '別件')

      put :update, params: { id: filter.id, preserve_expiry: true, expires_in: 5.minutes.to_i }

      expect(response).to have_http_status(200)
      filter.reload
      expect(filter.action).to eq 'hide'
      expect(filter.context).to eq %w(home thread)
      expect(filter.expires_at).to be_within(1.second).of(expiry)
      expect(filter.keywords.pluck(:keyword)).to eq ['別件']
      expect(body_as_json[:filter_action]).to eq 'hide'
    end

    it 'does not accept keeping the end time of a mute that has already ended' do
      filter = HashtagMutes::UpsertService.new.call(user.account, name: '番組', expires_in: 5.minutes.to_i)
      filter.update!(expires_at: 1.minute.ago, action: :warn, context: %w(home))
      expiry = filter.expires_at

      put :update, params: { id: filter.id, preserve_expiry: true }

      expect(response).to have_http_status(422)
      filter.reload
      expect(filter.action).to eq 'warn'
      expect(filter.expires_at).to be_within(1.second).of(expiry)
      expect(filter.context).to eq %w(home)

      put :update, params: { id: filter.id, expires_in: 2.hours.to_i }

      expect(response).to have_http_status(200)
      expect(filter.reload.action).to eq 'hide'
      expect(filter.expires_at).to be_within(5.seconds).of(2.hours.from_now)
      expect(filter.context).to eq %w(home)
    end
  end

  describe 'DELETE #destroy' do
    let(:scopes) { 'write:filters' }

    it 'removes the tag mute' do
      filter = HashtagMutes::UpsertService.new.call(user.account, name: '番組', expires_in: nil)

      delete :destroy, params: { id: filter.id }

      expect(response).to have_http_status(200)
      expect(CustomFilter.where(account: user.account)).to be_empty
      expect(CustomFilterTag.where(account: user.account)).to be_empty
    end

    it 'removes only the tag when the filter also has a keyword or an individual post' do
      filter = HashtagMutes::UpsertService.new.call(user.account, name: '番組', expires_in: 300)
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: '別件')
      status = Fabricate(:status, account: user.account)
      Fabricate(:custom_filter_status, custom_filter: filter, status: status)

      delete :destroy, params: { id: filter.id }

      expect(response).to have_http_status(200)
      kept = CustomFilter.find(filter.id)
      expect(kept.keywords.pluck(:keyword)).to eq ['別件']
      expect(kept.statuses.pluck(:status_id)).to eq [status.id]
      expect(kept.filter_tags).to be_empty
    end
  end
end
