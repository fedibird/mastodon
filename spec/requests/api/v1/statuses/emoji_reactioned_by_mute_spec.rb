# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji reaction authors with a local mute', type: :request do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:favourites') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:status) { Fabricate(:status, account: Fabricate(:account), visibility: :public) }

  it 'keeps unicode, another local emoji, and a remote emoji when one local emoji is hidden' do
    muted = Fabricate(:custom_emoji, shortcode: 'muted_emoji')
    other = Fabricate(:custom_emoji, shortcode: 'other_emoji')
    remote = Fabricate(:custom_emoji, shortcode: 'remote_emoji', domain: 'remote.example')
    unicode = Fabricate(:account)
    local_muted = Fabricate(:account)
    local_other = Fabricate(:account)
    remote_actor = Fabricate(:account)
    EmojiReaction.create!(account: unicode, status: status, name: '👍')
    EmojiReaction.create!(account: local_muted, status: status, name: muted.shortcode, custom_emoji: muted)
    EmojiReaction.create!(account: local_other, status: status, name: other.shortcode, custom_emoji: other)
    EmojiReaction.create!(account: remote_actor, status: status, name: remote.shortcode, custom_emoji: remote)
    EmojiMutes::Repository.new(user).create({
      'emoji' => { 'kind' => 'custom', 'custom_emoji_id' => muted.id.to_s },
      'effects' => {
        'replace_in_text' => false,
        'reject_reactions_to_own_posts' => false,
        'hide_reactions' => true,
        'hide_in_picker' => false,
      },
    })

    get "/api/v1/statuses/#{status.id}/emoji_reactioned_by", headers: headers

    expect(response).to have_http_status(:ok)
    ids = JSON.parse(response.body).map { |row| row.dig('account', 'id') }
    expect(ids).to include(unicode.id.to_s, local_other.id.to_s, remote_actor.id.to_s)
    expect(ids).not_to include(local_muted.id.to_s)
  end
end
