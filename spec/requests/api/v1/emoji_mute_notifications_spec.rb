# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute notification visibility' do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.current, last_sign_in_at: Time.current) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:notifications') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:status) { Fabricate(:status, account: user.account) }
  let(:reactor) { Fabricate(:account) }

  def reaction_notification(name = '👍')
    reaction = EmojiReaction.create!(account: reactor, status: status, name: name)
    Fabricate(:notification, account: user.account, from_account: reactor, activity: reaction, type: :emoji_reaction)
  end

  it 'filters the index, unread count, and show before pagination, then restores them' do
    favourite = Fabricate(:notification, account: user.account, from_account: reactor, activity: Fabricate(:favourite, account: reactor, status: status), type: :favourite)
    hidden = reaction_notification
    EmojiMutes::Repository.new(user).create({
      'emoji' => { 'kind' => 'unicode', 'native' => '👍' },
      'effects' => {
        'replace_in_text' => true,
        'reject_reactions_to_own_posts' => false,
        'hide_reactions' => true,
        'hide_in_picker' => true,
      },
    })

    get '/api/v1/notifications', params: { limit: 1 }, headers: headers
    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(body.map { |row| row['id'] }).to eq [favourite.id.to_s]
    expect(body.map { |row| row['id'] }).not_to include(hidden.id.to_s)

    get '/api/v1/notifications/unread_count', headers: headers
    expect(JSON.parse(response.body)['count']).to eq 1

    get "/api/v1/notifications/#{hidden.id}", headers: headers
    expect(response).to have_http_status(:not_found)

    EmojiMute.where(user: user).delete_all
    EmojiMutes::Store.rule_sets = nil
    get "/api/v1/notifications/#{hidden.id}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'skips push and mail that were queued before the mute' do
    notification = reaction_notification
    EmojiMutes::Repository.new(user).create({ 'emoji' => { 'kind' => 'unicode', 'native' => '👍' } })
    subscription = Fabricate(:web_push_subscription, user_id: user.id, key_p256dh: 'BN4GvZtEZiZuqFxSKVZfSfluwKBD7UxHNBmWkfiZfCtgDE8Bwh-_MtLXbBxTBAWH9r7IPKL0lhdcaqtL1dfxU5E=', key_auth: 'Q2BoAjC09xH3ywDLNJr-dA==', endpoint: 'https://updates.push.services.mozilla.com/push/v1/subscription-id', data: { alerts: { emoji_reaction: true } })
    allow_any_instance_of(subscription.class).to receive(:pushable?).and_return(true)
    expect(Web::PushNotificationWorker.new.perform(subscription.id, notification.id)).not_to be false
    expect(a_request(:post, subscription.endpoint)).not_to have_been_made

    expect { NotificationMailer.emoji_reaction(user.account, notification).deliver_now }.not_to change { ActionMailer::Base.deliveries.size }
  end
end
