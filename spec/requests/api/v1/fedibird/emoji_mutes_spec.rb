# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute API', type: :request do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:mutes write:mutes') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:path) { '/api/v1/fedibird/emoji_mutes' }

  def parsed
    JSON.parse(response.body)
  end

  def post_mute(emoji, extra = {})
    post path, params: extra.merge(emoji: emoji).to_json, headers: headers
  end

  it 'isolates the owner, scopes, limits, and does not fetch or copy emoji' do
    post path, params: { emoji: { kind: 'unicode', native: '👍🏽' } }.to_json
    expect(response).to have_http_status(:unauthorized)

    token.update!(scopes: 'read:statuses')
    get path, headers: headers
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'read:mutes')
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq 'private, no-store'
    expect(parsed).to include('revision' => '0', 'emoji_mutes' => [])
    expect(parsed.dig('effect_application', 'stored_only')).to eq %w(replace_in_text hide_in_picker)

    token.update!(scopes: 'write:accounts')
    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'write')
    expect(ResolveURLService).not_to receive(:new)
    expect { post_mute({ kind: 'unicode', native: '👍🏽' }, user_id: Fabricate(:user).id.to_s) }.not_to change(CustomEmoji, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'unknown_field'

    post path, params: { emoji: { kind: 'unicode', native: '👍🏽' }, padding: 'x' * (512 * 1024) }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'too_large'
  end

  it 'stores unicode, local id, and remote identity and keeps them after the emoji is gone' do
    token.update!(scopes: 'write:mutes read:mutes')
    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:created)
    expect(parsed.dig('emoji_mute', 'effects').values).to all(be true)
    expect(parsed.dig('emoji_mute', 'replacement')).to eq '［絵文字］'
    expect(parsed.dig('emoji_mute', 'emoji')).to eq('kind' => 'unicode', 'native' => '👍🏽')
    unicode_id = parsed.dig('emoji_mute', 'id')
    expect(response.headers['ETag']).to eq %("#{unicode_id}-1")

    local = Fabricate(:custom_emoji, shortcode: 'wide_emoji', disabled: true)
    post_mute(kind: 'custom', shortcode: 'wide_emoji')
    expect(response).to have_http_status(:created)
    expect(parsed.dig('emoji_mute', 'emoji', 'custom_emoji_id')).to eq local.id.to_s
    local_id = parsed.dig('emoji_mute', 'id')
    pinned = local.id
    local.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'wide_emoji')

    remote = Fabricate(:custom_emoji, shortcode: 'wide_emoji', domain: 'remote.example')
    post_mute(kind: 'custom', scope: 'remote', domain: 'Remote.Example', shortcode: 'wide_emoji')
    expect(parsed.dig('emoji_mute', 'emoji')).to eq('kind' => 'custom', 'scope' => 'remote', 'domain' => 'remote.example', 'shortcode' => 'wide_emoji')
    expect(parsed.dig('emoji_mute', 'detail', 'cache_id')).to eq remote.id.to_s
    remote_rule = parsed.dig('emoji_mute', 'id')
    remote.destroy!

    expect { get path, headers: headers }.not_to change(CustomEmoji, :count)
    body = parsed.fetch('emoji_mutes')
    expect(body.map { |row| row['id'] }).to eq [unicode_id, local_id, remote_rule]
    local_row = body.find { |row| row['id'] == local_id }
    expect(local_row.dig('emoji', 'custom_emoji_id')).to eq pinned.to_s
    expect(local_row.dig('emoji', 'custom_emoji_id')).not_to eq replacement.id.to_s
    expect(local_row.dig('detail', 'state')).to eq 'unavailable'
    remote_row = body.find { |row| row['id'] == remote_rule }
    expect(remote_row.dig('detail', 'state')).to eq 'unfetched'
    expect(remote_row.dig('detail')).not_to have_key('cache_id')

    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:conflict)
    expect(parsed.dig('errors', 0, 'code')).to eq 'duplicate'
    expect(EmojiMute.where(user_id: user.id).count).to eq 3
  end

  it 'patches only the supplied fields, accepts an empty replacement, and guards revision' do
    token.update!(scopes: 'read:mutes write:mutes')
    post_mute(kind: 'unicode', native: '👍🏽')
    id = parsed.dig('emoji_mute', 'id')
    item = "#{path}/#{id}"

    patch item, params: { expected_revision: '1', effects: { hide_in_picker: false }, replacement: '' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('emoji_mute', 'revision')).to eq '2'
    expect(parsed.dig('emoji_mute', 'replacement')).to eq ''
    expect(parsed.dig('emoji_mute', 'effects')).to include(
      'hide_in_picker' => false,
      'hide_reactions' => true,
      'reject_reactions_to_own_posts' => true,
      'replace_in_text' => true
    )

    patch item, params: { expected_revision: '1', effects: { hide_reactions: false } }.to_json, headers: headers
    expect(response).to have_http_status(:conflict)
    expect(EmojiMute.find(id).hide_reactions).to be true

    patch item, params: {
      expected_revision: '2',
      effects: {
        replace_in_text: false,
        reject_reactions_to_own_posts: false,
        hide_reactions: false,
        hide_in_picker: false,
      },
    }.to_json, headers: headers.merge('If-Match' => "\"#{id}-9\"")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'contradictory_field'

    patch item, params: {
      expected_revision: '2',
      effects: {
        replace_in_text: false,
        reject_reactions_to_own_posts: false,
        hide_reactions: false,
        hide_in_picker: false,
      },
    }.to_json, headers: headers.merge('If-Match' => "\"#{id}-2\"")
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('emoji_mute', 'effects').values).to all(be false)
    expect(parsed.dig('revision')).to eq '3'

    get path, headers: headers.merge('If-None-Match' => 'W/"emoji-mutes-3"')
    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
    expect(response.headers['Cache-Control']).to eq 'private, no-store'

    other = Fabricate(:user)
    other_token = Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'write:mutes')
    delete item, params: { expected_revision: '3' }.to_json, headers: headers.merge('Authorization' => "Bearer #{other_token.token}")
    expect(response).to have_http_status(:not_found)
    expect(EmojiMute.find(id)).to be_present

    set = PersonalEmojiSet.create!(user: user, categories: [], revision: 4)
    delete item, params: { expected_revision: '2' }.to_json, headers: headers
    expect(response).to have_http_status(:conflict)
    delete item, params: { expected_revision: '3' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed).to eq('revision' => '4')
    expect(EmojiMute.where(id: id)).to be_empty
    expect(set.reload.categories).to eq []
    expect(set.revision).to eq 4
  end

  it 'rejects an oversized replacement and a second rule past the cap' do
    token.update!(scopes: 'write:mutes')
    stub_const('EmojiMute::MAX_PER_USER', 1)
    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:created)

    post_mute(kind: 'unicode', native: '🎉')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'limit_reached'

    delete "#{path}/#{EmojiMute.last.id}", params: { expected_revision: '1' }.to_json, headers: headers
    post_mute({ kind: 'unicode', native: '🎉' }, replacement: 'あ' * 33)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'too_long'
    expect(EmojiMute.where(user_id: user.id)).to be_empty
  end
end
