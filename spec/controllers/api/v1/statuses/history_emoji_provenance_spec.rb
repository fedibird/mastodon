# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::HistoriesController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses') }
  let(:emoji) { Fabricate(:custom_emoji, shortcode: 'blob') }
  let(:status) { Fabricate(:status, account: user.account, text: 'hello :blob:', visibility: :public) }

  before do
    emoji
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def emoji_ids
    body_as_json.flat_map { |item| Array(item[:emojis]).map { |row| row[:id] } }
  end

  it 'keeps the id captured when the revision was saved after that emoji is replaced' do
    status.snapshot!(at_time: status.created_at, rate_limit: false)
    original_id = emoji.id.to_s
    emoji.destroy!
    replacement = Fabricate(:custom_emoji, shortcode: 'blob')

    get :show, params: { status_id: status.id }

    expect(response).to have_http_status(200)
    expect(emoji_ids).not_to include(replacement.id.to_s)
    expect(emoji_ids).not_to include(original_id)
    expect(body_as_json.first[:content]).to include(':blob:')
    expect(status.edits.last.emoji_identities).to include(hash_including('id' => original_id, 'shortcode' => 'blob'))
  end

  it 'serializes the snapshotted local id while that row still exists' do
    status.snapshot!(at_time: status.created_at, rate_limit: false)

    get :show, params: { status_id: status.id }

    expect(emoji_ids).to eq [emoji.id.to_s]
  end

  it 'does not treat a legacy revision as the current shortcode row' do
    legacy = status.edits.create!(
      text: 'old :blob:',
      spoiler_text: '',
      account: user.account,
      created_at: 1.hour.ago,
      emoji_identities: nil
    )

    get :show, params: { status_id: status.id }

    legacy_json = body_as_json.find { |item| item[:content].include?('old :blob:') }

    expect(legacy.emoji_identities).to be_nil
    expect(legacy_json[:emojis]).to eq []
    expect(legacy_json[:content]).to include(':blob:')
  end
end
