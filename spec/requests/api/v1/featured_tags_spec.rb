# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'FeaturedTags' do
  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      expect(response).to have_http_status(403)
    end
  end

  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes)  { 'read:accounts write:accounts' }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  describe 'GET /api/v1/featured_tags' do
    context 'with wrong scope' do
      before do
        get '/api/v1/featured_tags', headers: headers
      end

      it_behaves_like 'forbidden for wrong scope', 'read:statuses'
    end

    context 'when Authorization header is missing' do
      it 'returns http unauthorized' do
        get '/api/v1/featured_tags'

        expect(response).to have_http_status(401)
      end
    end

    it 'returns http success' do
      get '/api/v1/featured_tags', headers: headers

      expect(response).to have_http_status(200)
    end

    context 'when the requesting user has no featured tag' do
      before do
        3.times { |index| FeaturedTag.create!(account: Fabricate(:account), name: "other#{index}") }
      end

      it 'returns an empty body' do
        get '/api/v1/featured_tags', headers: headers

        body = body_as_json

        expect(body).to be_empty
      end
    end

    context 'when the requesting user has featured tags' do
      let!(:user_featured_tags) do
        Array.new(5) { |index| FeaturedTag.create!(account: user.account, name: "usertag#{index}") }
      end

      it 'returns only the featured tags belonging to the requesting user' do
        get '/api/v1/featured_tags', headers: headers

        body = body_as_json
        expected_ids = user_featured_tags.pluck(:id).map(&:to_s)

        expect(body.pluck(:id)).to match_array(expected_ids)
      end

      it 'returns statuses_count as a string and last_status_at as a date' do
        featured_tag = user_featured_tags.first
        featured_tag.update_columns(statuses_count: 12, last_status_at: Time.utc(2026, 9, 27, 12, 34, 56))

        get '/api/v1/featured_tags', headers: headers

        json = body_as_json.find { |item| item[:id] == featured_tag.id.to_s }

        expect(json[:statuses_count]).to eq('12')
        expect(json[:statuses_count]).to be_a(String)
        expect(json[:last_status_at]).to eq('2026-09-27')
      end
    end
  end

  describe 'POST /api/v1/featured_tags' do
    let(:params) { { name: 'tag' } }

    it 'returns http success' do
      post '/api/v1/featured_tags', headers: headers, params: params

      expect(response).to have_http_status(200)
    end

    it 'returns the correct tag name' do
      post '/api/v1/featured_tags', headers: headers, params: params

      body = body_as_json

      expect(body[:name]).to eq(params[:name])
    end

    it 'creates a new featured tag for the requesting user' do
      post '/api/v1/featured_tags', headers: headers, params: params

      featured_tag = FeaturedTag.by_name(params[:name]).find_by(account: user.account)

      expect(featured_tag).to be_present
    end

    context 'with wrong scope' do
      before do
        post '/api/v1/featured_tags', headers: headers, params: params
      end

      it_behaves_like 'forbidden for wrong scope', 'read:statuses'
    end

    context 'when Authorization header is missing' do
      it 'returns http unauthorized' do
        post '/api/v1/featured_tags', params: params

        expect(response).to have_http_status(401)
      end
    end

    context 'when required param "name" is not provided' do
      it 'returns http bad request and does not create a featured tag' do
        expect { post '/api/v1/featured_tags', headers: headers }.to_not change(FeaturedTag, :count)

        expect(response).to have_http_status(400)
      end
    end

    context 'when provided tag name is invalid' do
      let(:params) { { name: 'asj&*!' } }

      it 'returns http unprocessable entity' do
        post '/api/v1/featured_tags', headers: headers, params: params

        expect(response).to have_http_status(422)
      end
    end

    context 'when tag name is already taken' do
      before do
        FeaturedTag.create(name: params[:name], account: user.account)
      end

      it 'returns http unprocessable entity' do
        post '/api/v1/featured_tags', headers: headers, params: params

        expect(response).to have_http_status(422)
      end
    end
  end

  describe 'DELETE /api/v1/featured_tags' do
    let!(:featured_tag) { FeaturedTag.create(name: 'tag', account: user.account) }
    let(:id) { featured_tag.id }

    it 'returns http success' do
      delete "/api/v1/featured_tags/#{id}", headers: headers

      expect(response).to have_http_status(200)
    end

    it 'returns an empty body' do
      delete "/api/v1/featured_tags/#{id}", headers: headers

      body = body_as_json

      expect(body).to be_empty
    end

    it 'deletes the featured tag' do
      delete "/api/v1/featured_tags/#{id}", headers: headers

      featured_tag = FeaturedTag.find_by(id: id)

      expect(featured_tag).to be_nil
    end

    context 'with wrong scope' do
      before do
        delete "/api/v1/featured_tags/#{id}", headers: headers
      end

      it_behaves_like 'forbidden for wrong scope', 'read:statuses'
    end

    context 'when Authorization header is missing' do
      it 'returns http unauthorized' do
        delete "/api/v1/featured_tags/#{id}"

        expect(response).to have_http_status(401)
      end
    end

    context 'when featured tag with given id does not exist' do
      it 'returns http not found' do
        delete '/api/v1/featured_tags/0', headers: headers

        expect(response).to have_http_status(404)
      end
    end

    context 'when deleting a featured tag of another user' do
      let!(:other_user_featured_tag) { FeaturedTag.create!(account: Fabricate(:account), name: 'othertag') }
      let(:id) { other_user_featured_tag.id }

      it 'returns http not found' do
        delete "/api/v1/featured_tags/#{id}", headers: headers

        expect(response).to have_http_status(404)
      end
    end
  end
end
