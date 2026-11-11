# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::HistoriesController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses') }
  let(:emoji) { Fabricate(:custom_emoji, shortcode: 'blob') }

  before do
    emoji
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  it 'does not attach a re-registered local id to the original post after the first edit' do
    posted = PostStatusService.new.call(user.account, text: 'hello :blob:', visibility: 'public')
    original_id = emoji.id.to_s

    expect(posted.emoji_identities).to include(hash_including('id' => original_id, 'shortcode' => 'blob'))

    emoji.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'blob')
    UpdateStatusService.new.call(posted, user.account.id, text: 'hello :blob: edited')

    get :show, params: { status_id: posted.id }

    original = body_as_json.find { |item| item[:content].include?('hello :blob:') && !item[:content].include?('edited') }
    edited = body_as_json.find { |item| item[:content].include?('edited') }

    expect(response).to have_http_status(200)
    expect(original[:emojis]).to eq []
    expect(original[:content]).not_to include(replacement.id.to_s)
    expect(original[:content]).to include(':blob:')
    expect(edited[:emojis].map { |row| row[:id] }).to eq [replacement.id.to_s]
    expect(posted.edits.first.emoji_identities).to include(hash_including('id' => original_id, 'shortcode' => 'blob'))
    expect(posted.edits.first.emoji_identities.map { |row| row['id'] }).not_to include(replacement.id.to_s)
  end

  it 'leaves local emoji unproven when the post never recorded an identity' do
    posted = PostStatusService.new.call(user.account, text: 'hello :blob:', visibility: 'public')
    posted.update_column(:emoji_identities, nil)
    emoji.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'blob')
    UpdateStatusService.new.call(posted, user.account.id, text: 'hello :blob: later')

    get :show, params: { status_id: posted.id }

    original = body_as_json.find { |item| item[:content].include?('hello :blob:') && !item[:content].include?('later') }

    expect(original[:emojis]).to eq []
    expect(original[:content]).not_to include(replacement.id.to_s)
    expect(posted.edits.first.emoji_identities).to eq []
  end
end
