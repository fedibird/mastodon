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

RSpec.describe StatusEdit, type: :model do
  let(:status) { Fabricate(:status, text: 'remote history') }

  def selects_for(custom_emojis_sql)
    custom_emojis_sql.select { |sql| sql.include?('custom_emojis') && sql.start_with?('SELECT') }
  end

  it 'loads every remote identity pair in one query and does not mix domains' do
    included = Array.new(10) { |index| Fabricate(:custom_emoji, shortcode: 'blob', domain: "remote#{index}.example") }
    decoy = Fabricate(:custom_emoji, shortcode: 'blob', domain: 'other.example')
    identities = included.map { |emoji| { 'id' => nil, 'shortcode' => 'blob', 'domain' => emoji.domain } }
    edits = Array.new(2) do
      described_class.new(status: status, text: 'hello :blob:', spoiler_text: '', emoji_identities: identities)
    end
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql]
    end

    loaded = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      edits.map(&:emojis)
    end

    expect(selects_for(queries).size).to eq(2)
    expect(loaded.first.map(&:domain)).to match_array(included.map(&:domain))
    expect(loaded.first.map(&:id)).not_to include(decoy.id)
    expect(loaded.second.map(&:id)).to match_array(loaded.first.map(&:id))
  end
end
