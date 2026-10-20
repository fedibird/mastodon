# frozen_string_literal: true

require 'rails_helper'

describe 'AT Protocol OAuth attempt retention' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }

  after do
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
  end

  def attempt_attributes(owner, suffix, expires_at:, consumed_at: nil, created_at: Time.current, secret: "ciphertext-#{suffix}")
    now = Time.current
    {
      user_id: owner.id,
      provider: 'bluesky',
      state_digest: Digest::SHA256.hexdigest("state-#{owner.id}-#{suffix}"),
      browser_binding_digest: Digest::SHA256.hexdigest("browser-#{suffix}"),
      input_kind: 'handle',
      issuer: 'https://entry.example',
      authorization_endpoint: 'https://entry.example/oauth/authorize',
      token_endpoint: 'https://entry.example/oauth/token',
      par_endpoint: 'https://entry.example/oauth/par',
      redirect_uri: 'https://cb6e6126.ngrok.io/settings/external_services/bluesky/callback',
      requested_scopes: 'atproto',
      binding_id: SecureRandom.uuid,
      encrypted_secrets: secret,
      encryption_key_id: 'v2',
      client_key_id: 'par-kid',
      expires_at: expires_at,
      consumed_at: consumed_at,
      created_at: created_at,
      updated_at: now,
    }
  end

  def store_attempt!(...)
    ExternalOauthAttempt.create!(attempt_attributes(...))
  end

  it 'deletes abandoned and consumed attempts and keeps an active one for each owner' do
    abandoned = store_attempt!(user, 'abandoned', expires_at: 1.hour.ago, secret: 'verifier-SENTINEL-abandoned')
    consumed = store_attempt!(user, 'consumed', expires_at: 5.minutes.from_now, consumed_at: Time.current, secret: 'verifier-SENTINEL-consumed')
    active = store_attempt!(user, 'active', expires_at: 5.minutes.from_now, secret: 'verifier-SENTINEL-active')
    theirs = store_attempt!(other, 'theirs', expires_at: 5.minutes.from_now, secret: 'verifier-SENTINEL-theirs')
    theirs_old = store_attempt!(other, 'theirs-old', expires_at: 1.hour.ago, secret: 'verifier-SENTINEL-theirs-old')
    active_secret = active.encrypted_secrets
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| queries << payload[:sql].to_s }

    expect(ExternalBridge::Atproto::AttemptBox).not_to receive(:decrypt)
    removed = ExternalBridge::Atproto::AttemptCleanup.call

    expect(removed).to eq(3)
    expect(ExternalOauthAttempt.where(id: [abandoned.id, consumed.id, theirs_old.id])).to be_empty
    expect(ExternalOauthAttempt.find(active.id).encrypted_secrets).to eq(active_secret)
    expect(ExternalOauthAttempt.find(theirs.id).user_id).to eq(other.id)
    expect(queries.join).not_to include('verifier-SENTINEL')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'stops after the batch cap and continues on the next run' do
    cap = ExternalBridge::Atproto::AttemptCleanup::BATCH * ExternalBridge::Atproto::AttemptCleanup::MAX_BATCHES
    rows = Array.new(cap + 1) { |index| attempt_attributes(user, "bulk-#{index}", expires_at: 2.hours.ago) }
    live = attempt_attributes(other, 'still-live', expires_at: 30.minutes.from_now, secret: 'verifier-SENTINEL-live')
    ExternalOauthAttempt.insert_all!(rows + [live])

    expect(ExternalBridge::Atproto::AttemptBox).not_to receive(:decrypt)
    first = Scheduler::ExternalBridgeAtprotoAttemptCleanupScheduler.new.perform
    expect(first).to eq(cap)
    expect(ExternalOauthAttempt.where(user_id: user.id).count).to eq(1)
    expect(ExternalOauthAttempt.where(user_id: other.id).count).to eq(1)

    second = ExternalBridge::Atproto::AttemptCleanup.call
    expect(second).to eq(1)
    expect(ExternalOauthAttempt.where(user_id: user.id)).to be_empty
    expect(ExternalOauthAttempt.find_by(user_id: other.id).encrypted_secrets).to eq('verifier-SENTINEL-live')
  end

  it 'rejects a new authorization at the outstanding cap without sending PAR' do
    enable_atproto!(user)
    with_atproto_client do
      ExternalBridge::Atproto::AttemptLimiter::OUTSTANDING_LIMIT.times do |index|
        store_attempt!(user, "open-#{index}", expires_at: 5.minutes.from_now)
      end
      reset_atproto_exchanges!
      expect(atproto_error { start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: atproto_dns) }.code).to eq('attempt_rate_limited')
      expect(ExternalOauthAttempt.where(user_id: user.id).count).to eq(ExternalBridge::Atproto::AttemptLimiter::OUTSTANDING_LIMIT)
      expect(atproto_exchanges).to be_empty
    end
  end

  it 'counts recent consumed attempts toward the window and ignores another user' do
    enable_atproto!(user)
    with_atproto_client do
      world = install_atproto_world!
      ExternalBridge::Atproto::AttemptLimiter::WINDOW_LIMIT.times do |index|
        store_attempt!(other, "other-window-#{index}", expires_at: 5.minutes.from_now)
      end
      ExternalBridge::Atproto::AttemptLimiter::WINDOW_LIMIT.times do |index|
        store_attempt!(user, "window-#{index}", expires_at: 5.minutes.from_now, consumed_at: Time.current)
      end
      expect(atproto_error { start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns) }.code).to eq('attempt_rate_limited')

      ExternalOauthAttempt.where(user_id: user.id).delete_all
      store_attempt!(user, 'stale', expires_at: 2.hours.ago, created_at: 2.hours.ago)
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      expect(started[:state]).to be_present
      expect(ExternalOauthAttempt.where(user_id: user.id, consumed_at: nil).where('expires_at > ?', Time.current).count).to eq(1)
      expect(ExternalOauthAttempt.where(user_id: other.id).count).to eq(ExternalBridge::Atproto::AttemptLimiter::WINDOW_LIMIT)
    end
  end
end
