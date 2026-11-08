# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute API', type: :request do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read write', application: Fabricate(:application)) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:path) { '/api/v1/fedibird/emoji_mutes' }

  def parsed
    JSON.parse(response.body)
  end

  def post_mute(emoji, extra = {})
    post path, params: extra.merge(emoji: emoji).to_json, headers: headers
  end

  before do
    allow_any_instance_of(EmojiMutes::ChangeNotifier).to receive(:publish)
  end

  it 'rejects anonymous and wrong-scope clients and ignores another account id' do
    post path, params: { emoji: { kind: 'unicode', native: '👍🏽' } }.to_json, headers: { 'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:unauthorized)

    token.update!(scopes: 'read:statuses')
    get path, headers: headers
    expect(response).to have_http_status(:forbidden)

    token.update!(scopes: 'read:mutes')
    get path, params: { account_id: Fabricate(:account).id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('emoji_mutes')).to eq []
    expect(parsed.fetch('revision')).to eq 0
    expect(response.headers['Cache-Control']).to eq 'private, no-store'

    token.update!(scopes: 'write:accounts')
    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:forbidden)
  end

  it 'stores a unicode rule, rejects a duplicate and a stale revision, and deletes only the rule' do
    token.update!(scopes: 'write:mutes read:mutes')
    post_mute({ kind: 'unicode', native: '👍🏽' }, user_id: user.id.to_s)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'unknown_field'

    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:created)
    body = parsed
    expect(body.dig('emoji', 'native')).to eq '👍🏽'
    expect(body.fetch('effects').values).to all(be true)
    expect(body.fetch('replacement')).to eq '［絵文字］'
    expect(body.fetch('revision')).to eq 1
    id = body.fetch('id')

    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:conflict)
    expect(parsed.dig('errors', 0, 'code')).to eq 'duplicate'

    patch "#{path}/#{id}", params: { expected_revision: 1, effects: { hide_in_picker: false }, replacement: '' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.dig('effects', 'hide_in_picker')).to be false
    expect(parsed.dig('effects', 'hide_reactions')).to be true
    expect(parsed.fetch('replacement')).to eq ''
    etag = response.headers['ETag']

    patch "#{path}/#{id}", params: { expected_revision: 1, effects: { replace_in_text: false } }.to_json, headers: headers
    expect(response).to have_http_status(:conflict)

    get path, headers: headers.merge('If-None-Match' => etag)
    expect(response).to have_http_status(:not_modified)

    other = Fabricate(:user)
    other_token = Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'write:mutes')
    patch "#{path}/#{id}", params: { expected_revision: 2 }.to_json, headers: { 'Authorization' => "Bearer #{other_token.token}", 'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:not_found)

    delete "#{path}/#{id}", params: { expected_revision: 2 }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed.fetch('revision')).to eq 3
    expect(EmojiMute.where(account_id: user.account_id)).to be_none
    expect(response.body).not_to include('👍🏽')
  end

  it 'pins a local id, keeps a remote domain after the cache row is gone, and does not fetch' do
    local = Fabricate(:custom_emoji, shortcode: 'localcat')
    remote = Fabricate(:custom_emoji, shortcode: 'remotecat', domain: 'remote.example')
    expect(ResolveURLService).not_to receive(:new)

    post_mute(kind: 'custom', shortcode: 'localcat')
    expect(response).to have_http_status(:created)
    expect(parsed.dig('emoji', 'custom_emoji_id')).to eq local.id.to_s
    local_mute_id = parsed.fetch('id')

    local.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'localcat')
    get path, headers: headers
    listed = parsed.fetch('emoji_mutes').find { |row| row['id'] == local_mute_id }
    expect(listed.dig('emoji', 'custom_emoji_id')).to eq local.id.to_s
    expect(listed.dig('emoji', 'custom_emoji_id')).not_to eq replacement.id.to_s
    expect(listed.fetch('availability')).to eq 'unavailable'

    post_mute(kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'remotecat')
    expect(response).to have_http_status(:created)
    expect(parsed.dig('emoji').keys).to contain_exactly('kind', 'scope', 'domain', 'shortcode')
    expect(parsed.dig('detail', 'cache_id')).to eq remote.id.to_s
    remote_id = parsed.fetch('id')
    remote.destroy!
    expect(CustomEmoji.where(shortcode: 'remotecat')).to be_none

    get path, headers: headers
    remote_row = parsed.fetch('emoji_mutes').find { |row| row['id'] == remote_id }
    expect(remote_row.dig('emoji', 'domain')).to eq 'remote.example'
    expect(remote_row.fetch('availability')).to eq 'unfetched'
    expect(remote_row).not_to have_key('detail')

    post path, params: { emoji: { kind: 'unicode', native: 'nope-not-emoji' }, effects: { hide_reactions: 'yes' } }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)

    stub_const('EmojiMutes::MAX_PER_ACCOUNT', 2)
    post_mute(kind: 'unicode', native: '👍🏽')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq 'limit_reached'
  end

  it 'does not read or write emoji rows while listing an empty collection' do
    sql = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] if payload[:sql].match?(/emoji_mutes|emoji_mute_revisions|custom_emojis/i) && payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      get path, headers: headers
    end
    expect(response).to have_http_status(:ok)
    expect(sql).to be_empty
    expect(EmojiMuteRevision.where(account_id: user.account_id)).to be_none
  end
end
