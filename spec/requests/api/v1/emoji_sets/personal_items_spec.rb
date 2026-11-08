# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal emoji category item API', type: :request do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:accounts read:accounts') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:document_path) { '/api/v1/emoji_sets/personal' }
  let(:native) { '👍🏽' }
  let(:category_id) { 'favorites' }

  def parsed
    JSON.parse(response.body)
  end

  def item_path(id = category_id)
    "#{document_path}/categories/#{id}/items"
  end

  def seed!
    payload = {
      expected_revision: 0,
      expected_picker_emoji_size: 22,
      picker_emoji_size: 32,
      categories: [
        { id: category_id, name: 'よく選ぶ', heading: { mode: 'emoji', item_id: 'thumb' }, items: [{ id: 'thumb', kind: 'unicode', native: native }] },
        { id: 'other', name: 'その他', items: [] },
      ],
    }
    put document_path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
  end

  def add(emoji, revision: 1, id: category_id)
    post item_path(id), params: { expected_revision: revision, emoji: emoji }.to_json, headers: headers
  end

  it 'rejects a read token and cannot name another owner' do
    seed!
    token.update!(scopes: 'read:accounts')
    add({ kind: 'unicode', native: '👍🏻' })
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'write')
    post item_path, params: { expected_revision: 1, emoji: { kind: 'unicode', native: '👍🏻' }, user_id: Fabricate(:user).id }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 1
  end

  it 'appends one unicode emoji and preserves the rest of the document' do
    seed!
    get "#{document_path}/stock", headers: headers
    previous_etag = response.headers.fetch('ETag')

    add({ kind: 'unicode', native: '👍🏻' })
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq 'private, no-store'
    expect(parsed.fetch('revision')).to eq 2
    expect(parsed.fetch('picker_emoji_size')).to eq 32
    expect(parsed.dig('operation')).to eq('added' => true, 'category_id' => category_id, 'item_id' => parsed.dig('categories', 0, 'items', 1, 'id'))
    expect(parsed.dig('categories', 0, 'items').map { |item| item['native'] }).to eq [native, '👍🏻']
    expect(parsed.dig('categories', 0, 'heading')).to eq('mode' => 'emoji', 'item_id' => 'thumb')
    expect(parsed.dig('categories', 1, 'items')).to eq []
    expect(parsed.dig('categories', 0, 'items', 1, 'id')).to match(/\Ai[0-9a-f]{16}\z/)
    item_id = parsed.dig('operation', 'item_id')

    get "#{document_path}/stock", headers: headers.merge('If-None-Match' => previous_etag)
    expect(response).to have_http_status(:ok)
    expect(response.headers['ETag']).not_to eq previous_etag
    expect(parsed.dig('stock', 'categories', 0, 'items').map { |item| item.dig('reference', 'native') }).to eq [native, '👍🏻']

    get document_path, headers: headers
    expect(parsed).not_to have_key('operation')
    expect(parsed.dig('categories', 0, 'items', 1, 'id')).to eq item_id
  end

  it 'treats the same identity as a no-op and conflicts before checking availability' do
    seed!
    stored = PersonalEmojiSet.find_by!(user: user)
    add({ kind: 'unicode', native: native })
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('operation')).to include('added' => false, 'item_id' => 'thumb')
    expect(parsed.fetch('revision')).to eq 1
    expect(PersonalEmojiSet.find_by!(user: user).updated_at).to eq stored.updated_at

    disabled = Fabricate(:custom_emoji, shortcode: 'gone_emoji', disabled: true)
    add({ kind: 'custom', custom_emoji_id: disabled.id.to_s }, revision: 0)
    expect(response).to have_http_status(:conflict)
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 1
    expect(PersonalEmojiSets::PickerSize.current(user.id)).to eq 32
  end

  it 'adds an enabled unlisted emoji by id and rejects shortcode, disabled, deleted, and remote input' do
    seed!
    hidden = Fabricate(:custom_emoji, shortcode: 'quiet_emoji', visible_in_picker: false)
    add({ kind: 'custom', shortcode: hidden.shortcode })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 1

    add({ kind: 'custom', custom_emoji_id: hidden.id.to_s })
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('categories', 0, 'items').last.fetch('custom_emoji_id')).to eq hidden.id.to_s
    saved = parsed

    put document_path, params: {
      expected_revision: 2,
      expected_picker_emoji_size: 32,
      picker_emoji_size: 32,
      categories: saved.fetch('categories'),
    }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('categories', 0, 'items').last.fetch('custom_emoji_id')).to eq hidden.id.to_s

    hidden.update!(disabled: true)
    add({ kind: 'custom', custom_emoji_id: hidden.id.to_s }, revision: 3)
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('operation', 'added')).to be false
    expect(parsed.fetch('revision')).to eq 3

    disabled = Fabricate(:custom_emoji, shortcode: 'gone_emoji', disabled: true)
    add({ kind: 'custom', custom_emoji_id: disabled.id.to_s }, revision: 3)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'disabled'

    deleted = Fabricate(:custom_emoji, shortcode: 'deleted_emoji')
    deleted_id = deleted.id.to_s
    deleted.destroy!
    Fabricate(:custom_emoji, shortcode: 'deleted_emoji')
    add({ kind: 'custom', custom_emoji_id: deleted_id }, revision: 3)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'unavailable_emoji'

    remote = Fabricate(:custom_emoji, shortcode: 'remote_emoji', domain: 'remote.example')
    add({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: remote.shortcode }, revision: 3)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'remote_emoji'
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 3
    expect(PersonalEmojiSet.find_by!(user: user).categories.first.fetch('items').map { |item| item['custom_emoji_id'] }).to eq [nil, hidden.id.to_s]
  end

  it 'does not create a missing category or keep a partial write at the item limit' do
    add({ kind: 'unicode', native: '👍🏻' }, revision: 0, id: 'missing')
    expect(response).to have_http_status(:not_found)
    expect(parsed.fetch('code')).to eq 'category_not_found'
    expect(PersonalEmojiSet.where(user: user)).to be_empty

    add({ kind: 'unicode', native: '👍🏻' }, revision: 4, id: 'missing')
    expect(response).to have_http_status(:conflict)
    expect(PersonalEmojiSet.where(user: user)).to be_empty

    seed!
    record = PersonalEmojiSet.find_by!(user: user)
    full = Array.new(PersonalEmojiSets::Definition::MAX_CATEGORY_ITEMS) do |index|
      { 'id' => "e#{index}", 'kind' => 'unicode', 'native' => format('n%x', index), 'emoji_id' => 'x' }
    end
    record.update!(categories: record.categories.deep_dup.tap { |categories| categories.first['items'] = full })
    add({ kind: 'unicode', native: '👍🏻' })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'too_many_items'
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq 1
    expect(PersonalEmojiSet.find_by!(user: user).categories.first.fetch('items').size).to eq PersonalEmojiSets::Definition::MAX_CATEGORY_ITEMS
  end
end
