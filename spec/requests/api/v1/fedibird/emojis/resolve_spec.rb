# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji reference resolve API', type: :request do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:accounts') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:path) { '/api/v1/fedibird/emojis/resolve' }

  def parsed
    JSON.parse(response.body)
  end

  def post_emoji(emoji, extra = {})
    post path, params: extra.merge(emoji: emoji).to_json, headers: headers
  end

  it 'requires a read scope and does not accept another user id' do
    post path, params: { emoji: { kind: 'unicode', native: '👍🏽' } }.to_json
    expect(response).to have_http_status(:unauthorized)

    token.update!(scopes: 'read:statuses')
    post_emoji(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'read')
    post_emoji({ kind: 'unicode', native: '👍🏽' }, user_id: Fabricate(:user).id.to_s)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'unknown_field'
  end

  it 'returns unicode detail without loading a remote copy or writing' do
    writes = []
    listener = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      writes << sql if sql.match?(/custom_emojis|personal_emoji_sets/i) && sql.match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i)
    end

    expect(ResolveURLService).not_to receive(:new)
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      expect { post_emoji(kind: 'unicode', native: '👍🏽') }.not_to change { [CustomEmoji.count, PersonalEmojiSet.count] }
    end

    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq 'private, no-store'
    expect(parsed.fetch('reference')).to eq('kind' => 'unicode', 'native' => '👍🏽')
    expect(parsed.dig('detail', 'emoji_id')).to eq '+1'
    expect(parsed.dig('detail', 'state')).to eq 'resolved'
    expect(parsed.dig('detail', 'image', 'src')).to end_with '/emoji/1f44d-1f3fd.svg'
    expect(parsed.dig('detail', 'image', 'alt')).to eq '👍🏽'
    expect(parsed.dig('actions', 'add_to_personal_category', 'allowed')).to be true
    expect(parsed.dig('actions', 'mute')).to eq(
      'allowed' => true,
      'applied' => %w(reject_reactions_to_own_posts hide_reactions),
      'stored_only' => %w(replace_in_text hide_in_picker)
    )
    expect(parsed.dig('actions', 'request_registration')).to eq('allowed' => false, 'reason' => 'not_implemented')
    expect(writes).to be_empty
  end

  it 'sends the returned unicode reference back to resolve and to a category append' do
    token.update!(scopes: 'read:accounts write:accounts')
    post_emoji(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:ok)
    reference = parsed.fetch('reference')
    expect(reference).to eq('kind' => 'unicode', 'native' => '👍🏽')
    expect(reference).not_to have_key('emoji_id')
    expect(parsed.dig('detail', 'emoji_id')).to eq '+1'

    post_emoji(reference)
    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('reference')).to eq reference
    expect(parsed.dig('detail', 'emoji_id')).to eq '+1'

    put '/api/v1/emoji_sets/personal', params: {
      expected_revision: 0,
      expected_picker_emoji_size: 22,
      picker_emoji_size: 22,
      categories: [{ id: 'favorites', name: 'Favorites', items: [] }],
    }.to_json, headers: headers
    expect(response).to have_http_status(:ok)

    post '/api/v1/emoji_sets/personal/categories/favorites/items', params: { expected_revision: 1, emoji: reference }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('operation', 'added')).to be true
    expect(parsed.dig('categories', 0, 'items', 0)).to include('kind' => 'unicode', 'native' => '👍🏽', 'emoji_id' => '+1')
  end

  it 'keeps compound unicode sequences and rejects text that is not an emoji' do
    ['👨‍⚕️', '🕵️‍♀️', '1️⃣', '👩‍❤️‍💋‍👩', 'ℹ️'].each do |native|
      post_emoji(kind: 'unicode', native: native)
      expect(response).to have_http_status(:ok), native
      expect(parsed.dig('reference', 'native')).to eq native
    end

    post_emoji(kind: 'unicode', native: '<script>')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'invalid_unicode'
  end

  it 'pins a local id, keeps shortcode case, and does not follow a deleted row to its replacement' do
    emoji = Fabricate(:custom_emoji, shortcode: 'Wide_Emoji')
    other = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    post_emoji(kind: 'custom', shortcode: 'Wide_Emoji')
    expect(parsed.dig('reference', 'custom_emoji_id')).to eq emoji.id.to_s
    expect(parsed.dig('reference', 'custom_emoji_id')).not_to eq other.id.to_s

    emoji.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'Wide_Emoji')
    post_emoji(kind: 'custom', shortcode: 'Wide_Emoji')
    expect(parsed.dig('reference', 'custom_emoji_id')).to eq replacement.id.to_s
    post_emoji(kind: 'custom', custom_emoji_id: emoji.id.to_s)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'unavailable_emoji'
  end

  it 'resolves an enabled unlisted local emoji and refuses a disabled one for addition' do
    hidden = Fabricate(:custom_emoji, shortcode: 'quiet_emoji', visible_in_picker: false)
    post_emoji(kind: 'custom', shortcode: hidden.shortcode)
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('reference', 'custom_emoji_id')).to eq hidden.id.to_s
    expect(parsed.dig('actions', 'add_to_personal_category', 'allowed')).to be true
    expect(CustomEmoji.listed.where(id: hidden.id)).to be_empty

    hidden.update!(disabled: true)
    post_emoji(kind: 'custom', custom_emoji_id: hidden.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('detail', 'emoji', 'shortcode')).to eq 'quiet_emoji'
    expect(parsed.dig('actions', 'add_to_personal_category')).to eq('allowed' => false, 'reason' => 'disabled')
  end

  it 'does not turn a remote reference into the local emoji of the same shortcode' do
    local = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    remote = Fabricate(:custom_emoji, shortcode: 'wide_emoji', domain: 'remote.example')
    post_emoji(kind: 'custom', scope: 'remote', domain: 'Remote.Example', shortcode: 'wide_emoji')

    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('reference')).to eq('kind' => 'custom', 'scope' => 'remote', 'domain' => 'remote.example', 'shortcode' => 'wide_emoji')
    expect(parsed.dig('detail', 'state')).to eq 'fetched'
    expect(parsed.dig('detail', 'cache_id')).to eq remote.id.to_s
    expect(parsed.dig('reference').values).not_to include(local.id.to_s, remote.id.to_s)
    expect(parsed.dig('actions', 'add_to_personal_category', 'reason')).to eq 'remote_emoji'
    expect(parsed.dig('actions', 'request_registration', 'allowed')).to be false
  end

  it 'reports an unfetched remote emoji without copying it locally' do
    Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    expect(ResolveURLService).not_to receive(:new)
    expect { post_emoji(kind: 'custom', scope: 'remote', domain: 'missing.example', shortcode: 'wide_emoji') }.not_to change(CustomEmoji, :count)

    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('reference')).to include('scope' => 'remote', 'domain' => 'missing.example', 'shortcode' => 'wide_emoji')
    expect(parsed.fetch('detail')).to eq(
      'state' => 'unfetched',
      'kind' => 'custom',
      'scope' => 'remote',
      'domain' => 'missing.example',
      'shortcode' => 'wide_emoji'
    )
    expect(parsed.dig('detail')).not_to have_key('emoji')
    expect(parsed.fetch('reference')).not_to have_key('custom_emoji_id')
  end

  it 'normalizes an internationalized domain and rejects empty, local, and contradictory input' do
    normalized = TagManager.instance.normalize_domain('日本語.jp')
    remote = Fabricate(:custom_emoji, shortcode: 'flagme', domain: '日本語.jp')
    post_emoji(kind: 'custom', scope: 'remote', domain: '日本語.jp', shortcode: 'flagme')
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('reference', 'domain')).to eq normalized
    expect(parsed.dig('detail', 'cache_id')).to eq remote.id.to_s
    expect(normalized).not_to eq '日本語.jp'

    ['', ' ', 'not a domain', 'https://evil.example/emoji.png', Rails.configuration.x.local_domain].each do |domain|
      post_emoji(kind: 'custom', scope: 'remote', domain: domain, shortcode: 'flagme')
      expect(response).to have_http_status(:unprocessable_entity), domain.inspect
      expect(parsed.dig('errors', 0, 'code')).to eq 'invalid_domain'
    end

    Fabricate(:custom_emoji, shortcode: 'flagme')
    post_emoji(kind: 'custom', scope: 'local', domain: 'remote.example', shortcode: 'flagme')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'contradictory_scope'
    post_emoji(kind: 'custom', custom_emoji_id: remote.id.to_s)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'contradictory_scope'
  end

  it 'rejects unknown fields, mismatched identity, and oversized bodies' do
    emoji = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
    post_emoji(kind: 'custom', custom_emoji_id: emoji.id.to_s, shortcode: 'other_emoji')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'contradictory_field'

    post_emoji(kind: 'unicode', native: '👍🏽', image: 'https://example.invalid/emoji.svg')
    expect(parsed.dig('errors', 0, 'code')).to eq 'unknown_field'

    post path, params: { emoji: { kind: 'unicode', native: '👍🏽' }, padding: 'x' * (512 * 1024) }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'too_large'
    expect(CustomEmoji.where(shortcode: 'wide_emoji').count).to eq 1
  end

  it 'authorizes optional status and account context without returning their contents' do
    secret = 'secret-status-body-should-stay-hidden'
    visible = Fabricate(:status, account: Fabricate(:account), text: secret, visibility: :public)
    hidden = Fabricate(:status, account: Fabricate(:account), text: secret, visibility: :private)
    post_emoji({ kind: 'unicode', native: '👍🏽' }, context: { status_id: visible.id.to_s })
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(secret)

    post_emoji({ kind: 'unicode', native: '👍🏽' }, context: { status_id: hidden.id.to_s })
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(secret)

    blocked = Fabricate(:account)
    user.account.block!(blocked)
    post_emoji({ kind: 'unicode', native: '👍🏽' }, context: { account_id: blocked.id.to_s })
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(blocked.username)
  end
end
