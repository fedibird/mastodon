# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Media-only Home and List timelines' do
  let(:user) { Fabricate(:user) }
  let(:headers) { auth_headers_for(user, 'read:statuses read:lists') }
  let(:list) { Fabricate(:list, account: user.account) }

  let!(:older_media) { Fabricate(:status, account: user.account) }
  let!(:text_between) { Fabricate(:status, account: user.account) }
  let!(:newer_media) { Fabricate(:status, account: user.account) }
  let!(:newest_text) { Fabricate(:status, account: user.account) }

  before do
    attach_remote_test_image(older_media)
    attach_remote_test_image(newer_media)

    members = [older_media, text_between, newer_media, newest_text].map { |status| [status.id, status.id] }
    redis.zadd(FeedManager.instance.key(:home, user.account.id), members)
    redis.zadd(FeedManager.instance.key(:list, list.id), members)
  end

  shared_examples 'an indexed media-only timeline' do
    it 'filters before LIMIT, keeps pagination and does not repeat or skip older media' do
      get path, headers: headers, params: { only_media: true, limit: 1 }

      expect(response).to have_http_status(200)
      expect(body_as_json.pluck(:id)).to eq([newer_media.id.to_s])
      expect(response.headers.fetch('Link')).to include('only_media=true')

      get path, headers: headers, params: { only_media: true, limit: 1, max_id: newer_media.id }

      expect(response).to have_http_status(200)
      expect(body_as_json.pluck(:id)).to eq([older_media.id.to_s])
    end

    it 'preserves the full timeline when only_media is absent' do
      get path, headers: headers, params: { limit: 4 }

      expect(response).to have_http_status(200)
      expect(body_as_json.pluck(:id)).to eq([newest_text, newer_media, text_between, older_media].map { |status| status.id.to_s })
    end
  end

  context 'with the Home endpoint' do
    let(:path) { '/api/v1/timelines/home' }

    it_behaves_like 'an indexed media-only timeline'
  end

  context 'with the List endpoint' do
    let(:path) { "/api/v1/timelines/list/#{list.id}" }

    it_behaves_like 'an indexed media-only timeline'
  end
end
