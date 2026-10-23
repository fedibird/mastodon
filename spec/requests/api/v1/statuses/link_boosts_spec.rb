# frozen_string_literal: true

# POST /reblog and /unreblog on an external projection, as a client sees them.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'External projection boost', type: :request do
  let(:owner) { Fabricate(:user) }
  let(:url) { "https://example.com/posts/#{SecureRandom.hex(5)}" }
  let(:secrets) { %w(SECRET_BODY_a11ce SECRET_TEXT_a11ce SECRET_CW_a11ce SECRET_TITLE_a11ce) }
  let(:world) do
    external_project_for(owner, body: 'SECRET_BODY_a11ce').tap do |built|
      built[:source].update!(title: 'Safe Feed Title')
      built[:resource].update!(canonical_url: url, title: 'SECRET_TITLE_a11ce')
      built[:status].update_columns(text: 'SECRET_TEXT_a11ce', spoiler_text: 'SECRET_CW_a11ce')
    end
  end
  let(:projection) { world[:status] }
  let(:headers) { auth_headers_for(owner, 'read write') }

  def json
    JSON.parse(response.body)
  end

  def boost(status = projection, params: {}, as: headers)
    post "/api/v1/statuses/#{status.id}/reblog", params: params, headers: as
  end

  def unboost(status = projection, as: headers)
    post "/api/v1/statuses/#{status.id}/unreblog", headers: as
  end

  def fetch(status = projection, as: headers)
    get "/api/v1/statuses/#{status.id}", headers: as
  end

  def consent!(user = owner, visibility = 'public')
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: visibility)
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
  end

  after do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
  end

  it 'answers with the wrapper of the public link note and nothing of the projection' do
    consent!
    projection

    boost

    expect(response).to have_http_status(200)
    expect(json['id']).not_to eq(projection.id.to_s)
    expect(json['visibility']).to eq('public')
    expect(json['reblog']['id']).not_to eq(projection.id.to_s)
    expect(json['reblog']['visibility']).to eq('public')
    expect(json['reblog']['content']).to include(url)
    expect(json['reblog']['content']).to include('Safe Feed Title')
    expect(json['reblog']['account']['id']).to eq(owner.account_id.to_s)
    expect(json['reblog']).not_to have_key('fedibird_external')
    expect(json['fedibird_external']).to be_nil
    secrets.each { |secret| expect(response.body).not_to include(secret) }
    expect(response.body).not_to include(%("#{projection.id}"))
    expect(response.body).not_to include(projection.id.to_s) if projection.id.to_s.length > 8

    wrapper = Status.find(json['id'])
    expect(wrapper.reblog_of_id).to eq(json['reblog']['id'].to_i)
    expect(wrapper.account_id).to eq(owner.account_id)
  end

  it 'reports reblogged on the original id after boost and not after unboost' do
    consent!
    projection

    fetch
    expect(json['reblogged']).to be(false)
    expect(json['visibility']).to eq('direct')
    expect(json['visibility_ex']).to eq('external')

    boost
    fetch
    expect(json['id']).to eq(projection.id.to_s)
    expect(json['reblogged']).to be(true)
    expect(json['reblogs_count']).to eq(0)
    expect(json['visibility']).to eq('direct')

    unboost
    expect(response).to have_http_status(200)
    expect(json['id']).to eq(projection.id.to_s)
    expect(json['reblogged']).to be(false)
    expect(json['visibility']).to eq('direct')
    fetch
    expect(json['reblogged']).to be(false)
  end

  it 'repeats boost and unboost safely and shares again after an undo' do
    consent!
    projection

    boost
    first = json['id']
    boost
    expect(json['id']).to eq(first)
    unboost
    unboost
    expect(response).to have_http_status(200)
    expect(json['reblogged']).to be(false)
    boost
    expect(response).to have_http_status(200)
    expect(json['id']).not_to eq(first)

    expect(ExternalProjectionLinkBoost.where(projection_status_id: projection.id).pluck(:generation, :state)).to eq([[1, 'undone'], [2, 'active']])
    expect(ExternalProjectionLinkReference.where(user_id: owner.id).count).to eq(1)
  end

  it 'lists the original as reblogged in a bookmark page for the owner only' do
    consent!
    roommate = share_account_user(owner.account)
    Bookmark.create!(account: owner.account, status: projection)
    boost

    get '/api/v1/bookmarks', headers: headers

    entry = json.find { |item| item['id'] == projection.id.to_s }
    expect(entry['reblogged']).to be(true)

    get '/api/v1/bookmarks', headers: auth_headers_for(roommate, 'read write')
    expect(json.map { |item| item['id'] }).not_to include(projection.id.to_s)
  end

  it 'reads reblogged per user in compact bookmark pages and a mixed page of 40' do
    consent!
    boosted = projection
    plain = Array.new(19) { Fabricate(:status, visibility: :public) }
    others = Array.new(20) { external_project_for(owner)[:status] }
    ([boosted] + plain + others).each { |status| Bookmark.create!(account: owner.account, status: status) }
    boost(boosted)
    normal_boosted = plain.first
    post "/api/v1/statuses/#{normal_boosted.id}/reblog", headers: headers
    expect(response).to have_http_status(200)

    get '/api/v1/bookmarks', params: { limit: 40 }, headers: headers
    expect(response).to have_http_status(200)
    page = json
    expect(page.size).to eq(40)
    flags = page.to_h { |item| [item['id'], item['reblogged']] }
    expect(flags[boosted.id.to_s]).to be(true)
    expect(flags[normal_boosted.id.to_s]).to be(true)
    expect(flags.values.count(true)).to eq(2)

    get '/api/v1/bookmarks', params: { limit: 40, compact: true }, headers: headers
    expect(response).to have_http_status(200)
    compact = json['statuses'].to_h { |item| [item['id'], item['reblogged']] }
    expect(compact[boosted.id.to_s]).to be(true)
    expect(compact.values.count(true)).to eq(2)

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:name] != 'SCHEMA' && payload[:sql].include?('external_projection_link_boosts') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get '/api/v1/bookmarks', params: { limit: 40 }, headers: headers
    end
    expect(queries.size).to eq(1)

    unboost(boosted)
    get '/api/v1/bookmarks', params: { limit: 40 }, headers: headers
    expect(json.to_h { |item| [item['id'], item['reblogged']] }[boosted.id.to_s]).to be(false)
  end

  it 'hides the projection and the undo from another user of the same account' do
    consent!
    roommate = share_account_user(owner.account)
    consent!(roommate)
    projection
    boost

    boost(as: auth_headers_for(roommate, 'read write'))
    expect(response).to have_http_status(404)
    unboost(as: auth_headers_for(roommate, 'read write'))
    expect(response).to have_http_status(404)
    fetch(as: auth_headers_for(roommate, 'read write'))
    expect(response).to have_http_status(404)

    expect(ExternalProjectionLinkBoost.where(projection_status_id: projection.id).pluck(:state)).to eq(['active'])
    fetch
    expect(json['reblogged']).to be(true)
  end

  it 'answers 404 for another account, an administrator, and a read-only token' do
    consent!
    projection
    stranger = Fabricate(:user)
    role = UserRole.create!(name: 'Boost API admin', permissions: UserRole::FLAGS[:administrator], position: 50)
    admin = Fabricate(:user, role: role)
    [stranger, admin].each do |user|
      consent!(user)
      boost(as: auth_headers_for(user, 'read write'))
      expect(response).to have_http_status(404)
      unboost(as: auth_headers_for(user, 'read write'))
      expect(response).to have_http_status(404)
    end

    boost(as: auth_headers_for(owner, 'read'))
    expect(response).to have_http_status(403)
    boost(as: { 'Accept' => 'application/json' })
    expect(response).to have_http_status(401)
    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(Status.where(account_id: owner.account_id, external_projection: [false, nil]).count).to eq(0)
  end

  it 'does not touch anything while sharing is off or without consent' do
    projection
    enable_external_bridge_link_sharing!(owner)

    boost
    expect(response).to have_http_status(403)
    expect(json['error']).to eq('consent_required')

    Setting.external_bridge_link_sharing = false
    boost
    expect(response).to have_http_status(403)
    expect(json['error']).to eq('feature_disabled')

    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(ExternalProjectionLinkReference.count).to eq(0)
    expect(Status.where(account_id: owner.account_id, external_projection: [false, nil]).count).to eq(0)
  end

  it 'refuses a visibility or circle that does not match the consented scope' do
    consent!(owner, 'unlisted')
    projection

    boost(params: { visibility: 'public' })
    expect(response).to have_http_status(422)
    expect(json['error']).to eq('visibility_mismatch')
    boost(params: { visibility: 'mutual' })
    expect(json['error']).to eq('visibility_mismatch')
    boost(params: { circle_id: '123' })
    expect(response).to have_http_status(422)
    expect(json['error']).to eq('circle_rejected')
    expect(ExternalProjectionLinkReference.count).to eq(0)

    boost(params: { visibility: 'unlisted' })
    expect(response).to have_http_status(200)
    expect(json['visibility']).to eq('unlisted')
    expect(json['reblog']['visibility']).to eq('unlisted')
  end

  it 'keeps undo working after the flag goes off and consent is revoked' do
    consent!
    projection
    boost
    first_wrapper = json['id']
    ExternalBridge::LinkSharing::Policy.revoke!(user: owner)
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''

    fetch
    expect(json['reblogged']).to be(true)
    unboost
    expect(response).to have_http_status(200)
    expect(json['reblogged']).to be(false)
    boost
    expect(response).to have_http_status(403)
    expect(Status.unscoped.find_by(id: first_wrapper)&.deleted_at.present? || Status.unscoped.find_by(id: first_wrapper).nil?).to be(true)
  end

  it 'asks for an undo when the consented scope or the URL no longer matches the live share' do
    consent!(owner, 'unlisted')
    projection
    boost
    first = json['id']
    ExternalBridge::LinkSharing::Policy.change_visibility!(user: owner, visibility: 'public')
    notes = Status.where(account_id: owner.account_id, external_projection: [false, nil]).count

    boost

    expect(response).to have_http_status(409)
    expect(json['error']).to eq('share_outdated')
    expect(Status.where(account_id: owner.account_id, external_projection: [false, nil]).count).to eq(notes)
    fetch
    expect(json['reblogged']).to be(true)

    unboost
    boost
    expect(response).to have_http_status(200)
    expect(json['id']).not_to eq(first)
    expect(json['visibility']).to eq('public')
    expect(json['reblog']['visibility']).to eq('public')
  end

  it 'refuses a marked legacy personal projection with no note, mapping, or wrapper' do
    consent!
    allow(ExternalBridge::VisibilitySwitch).to receive(:enabled?).and_return(false)
    legacy = project_for(owner)
    legacy[:resource].update!(canonical_url: url)

    boost(legacy[:status])

    expect(response).to have_http_status(422)
    expect(json['error']).to eq('projection_not_canonical')
    expect(ExternalProjectionLinkReference.count).to eq(0)
    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(Status.where(account_id: owner.account_id, external_projection: [false, nil]).count).to eq(0)

    fetch(legacy[:status])
    expect(response).to have_http_status(200)
    expect(json['reblogged']).to be(false)
  end

  it 'refuses a note that was edited and does not leak why' do
    consent!
    projection
    boost
    reference = Status.find(json['reblog']['id'])
    unboost
    reference.update_columns(text: "#{reference.text}\nmy own words")

    boost

    expect(response).to have_http_status(422)
    expect(json['error']).to eq('reference_modified')
    expect(response.body).not_to include('my own words')
  end

  it 'leaves ordinary public and unlisted boosts exactly as they were' do
    author = Fabricate(:account)
    public_status = Fabricate(:status, account: author, visibility: :public)
    unlisted_status = Fabricate(:status, account: author, visibility: :unlisted)
    private_status = Fabricate(:status, account: author, visibility: :private)

    [public_status, unlisted_status].each do |status|
      boost(status)
      expect(response).to have_http_status(200)
      expect(json['reblog']['id']).to eq(status.id.to_s)
      expect(json['reblog']['reblogged']).to be(true)
      expect(owner.account.reblogged?(status)).to be(true)
      expect(status.reload.reblogs_count).to eq(1)

      fetch(status)
      expect(json['reblogged']).to be(true)

      unboost(status)
      expect(response).to have_http_status(200)
      expect(json['reblogged']).to be(false)
      expect(owner.account.reblogged?(status)).to be(false)
    end

    boost(private_status)
    expect(response).to have_http_status(404).or have_http_status(403).or have_http_status(422)
    expect(ExternalProjectionLinkBoost.count).to eq(0)
  end

  it 'still refuses the projection in the ordinary service after a share' do
    consent!
    projection
    boost

    expect { ReblogService.new.call(owner.account, projection) }.to raise_error(Mastodon::ValidationError)
    expect(Status.where(reblog_of_id: projection.id)).to be_empty
  end
end

# rubocop:enable Metrics/BlockLength
