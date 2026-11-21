# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute preference API', type: :request do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:mutes write:mutes') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' } }
  let(:path) { '/api/v1/fedibird/emoji_mute_preference' }

  def parsed
    JSON.parse(response.body)
  end

  it 'reports the default and saves an explicit off only when the write matches' do
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(parsed).to include('enabled' => false, 'explicit' => false, 'known' => true, 'modal' => true)

    patch path, params: { enabled: false }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed).to include('enabled' => false, 'explicit' => true, 'known' => true)
    expect(EmojiMutes::Preference.new(user.reload).explicit?).to eq(true)

    patch path, params: { enabled: 'no' }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq('invalid_type')
    expect(EmojiMutes::Preference.new(user.reload).enabled?).to eq(false)
  end

  it 'keeps a saved rule visible to the management list while effects are off' do
    token.update!(scopes: 'write read')
    post '/api/v1/fedibird/emoji_mutes', params: { emoji: { kind: 'unicode', native: '👍' } }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    expect(parsed['emoji_mute_enabled']).to eq(true)

    patch path, params: { enabled: false }.to_json, headers: headers
    expect(response).to have_http_status(:ok)

    get '/api/v1/fedibird/emoji_mutes', headers: headers
    expect(response).to have_http_status(:ok)
    expect(parsed['enabled']).to eq(false)
    expect(parsed['explicit']).to eq(true)
    expect(parsed['emoji_mutes'].length).to eq(1)
    expect(EmojiMutes::RuleSet.for_user(user).hide_any?).to eq(false)

    post '/api/v1/fedibird/emoji_mutes', params: { emoji: { kind: 'unicode', native: '🎉' } }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed.dig('errors', 0, 'code')).to eq('reenable_required')
    expect(EmojiMute.where(user_id: user.id).count).to eq(1)
  end
end
