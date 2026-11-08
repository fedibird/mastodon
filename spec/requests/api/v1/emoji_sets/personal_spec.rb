# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal emoji sets API', type: :request do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:accounts write:accounts') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:path) { '/api/v1/emoji_sets/personal' }
  let(:category) { { id: 'favorites', name: '横長', heading: { mode: 'initial' }, items: [{ id: 'thumb', kind: 'unicode', native: '👍🏽' }] } }
  let(:payload) { { expected_revision: 0, expected_picker_emoji_size: 22, picker_emoji_size: 32, categories: [category] } }

  def parsed
    JSON.parse(response.body)
  end

  it 'requires a token, and never permits one user to choose another owner' do
    get path
    expect(response).to have_http_status(:unauthorized)

    other = Fabricate(:user)
    get path, params: { user_id: other.id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed).to include('revision' => 0, 'categories' => [])
    put path, params: payload.merge(user_id: other.id).to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PersonalEmojiSet.where(user: [user, other])).to be_empty
  end

  it 'enforces separate read and write scopes, including the non-persisting resolve action' do
    token.update!(scopes: 'read:accounts')
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    post "#{path}/resolve", params: { kind: 'unicode', native: '👍🏽' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('item', 'native')).to eq '👍🏽'
    expect(PersonalEmojiSet.where(user: user)).to be_empty
    put path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'read:statuses')
    get "#{path}/stock", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it 'round-trips the definition, the size, and stock with placement-keyed editor metadata' do
    put path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed).to include('revision' => 1, 'picker_emoji_size' => 32)
    expect(parsed.dig('resolved_items', 'thumb', 'available')).to be true
    expect(parsed.dig('stock', 'categories', 0, 'heading')).to eq('text' => '横')
    expect(parsed.dig('stock', 'categories', 0, 'items', 0, 'selection', 'native')).to eq '👍🏽'
    saved = parsed

    get path, headers: headers
    expect(parsed).to eq saved
    expect(response.headers['Cache-Control']).to eq 'private, no-store'
  end

  it 'returns a conflict without changing either resource when the client is stale' do
    put path, params: payload.to_json, headers: headers
    put path, params: payload.merge(picker_emoji_size: 48, categories: []).to_json, headers: headers

    expect(response).to have_http_status(:conflict)
    expect(parsed['code']).to eq 'conflict'
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 1
    expect(PersonalEmojiSets::PickerSize.current(user.id)).to eq 32
  end

  it 'pins a custom identity at resolution and does not swap it to a same-shortcode replacement' do
    emoji = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    post "#{path}/resolve", params: { kind: 'custom', shortcode: emoji.shortcode }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    resolved = parsed.fetch('item')
    expect(resolved.fetch('custom_emoji_id')).to eq emoji.id.to_s
    emoji.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    category[:items] = [resolved.merge('id' => 'wide')]
    put path, params: payload.to_json, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.fetch('errors').first.fetch('code')).to eq 'unavailable_emoji'
    expect(PersonalEmojiSet.where(user: user)).to be_empty
    expect(replacement.id.to_s).not_to eq resolved.fetch('custom_emoji_id')
  end

  it 'keeps unavailable saved definitions and representatives on subsequent saves' do
    emoji = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    category[:items] = [{ id: 'wide', kind: 'custom', shortcode: emoji.shortcode }]
    category[:heading] = { mode: 'emoji', item_id: 'wide' }
    put path, params: payload.to_json, headers: headers
    saved = parsed
    emoji.update!(disabled: true)
    put path, params: payload.merge(expected_revision: 1, expected_picker_emoji_size: 32, categories: saved.fetch('categories')).to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(parsed.dig('categories', 0, 'heading')).to eq('mode' => 'emoji', 'item_id' => 'wide')
    expect(parsed.dig('categories', 0, 'items', 0, 'custom_emoji_id')).to eq emoji.id.to_s
    expect(parsed.dig('stock', 'categories', 0, 'items')).to eq []
    expect(parsed.dig('stock', 'categories', 0, 'heading')).to eq('text' => '横')
    expect(parsed.dig('resolved_items', 'wide', 'available')).to be false
  end

  it 'revalidates stock separately from definition revisions and keeps responses private' do
    emoji = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    category[:items] << { id: 'wide', kind: 'custom', shortcode: emoji.shortcode }
    put path, params: payload.to_json, headers: headers
    get "#{path}/stock", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq 'private, no-cache'
    etag = response.headers.fetch('ETag')
    get "#{path}/stock", headers: headers.merge('If-None-Match' => etag)
    expect(response).to have_http_status(:not_modified)

    emoji.update!(disabled: true)
    get "#{path}/stock", headers: headers.merge('If-None-Match' => etag)
    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('revision')).to eq 1
    expect(parsed.dig('stock', 'categories', 0, 'items').map { |item| item['key'] }).to eq ['thumb']
    expect(response.headers['ETag']).not_to eq etag
  end

  it 'rejects malformed JSON, non-object bodies, oversized input, and arbitrary image fields' do
    [']', '[]', { categories: 'x' * (512 * 1024) }.to_json].each do |invalid|
      put path, params: invalid, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
    category[:items].first[:image] = { src: 'https://example.org/untrusted.svg' }
    put path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PersonalEmojiSet.where(user: user)).to be_empty
  end
end
