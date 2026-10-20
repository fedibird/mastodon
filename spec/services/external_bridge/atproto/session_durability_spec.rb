# frozen_string_literal: true

require 'rails_helper'

describe 'AT Protocol session durability', type: :model do
  # A second database connection can see a marker only after it is committed.
  # The example transaction would hide that commit.
  self.use_transactional_tests = false

  def purge_atproto_user(user)
    return unless user&.persisted?

    ExternalOauthAttempt.where(user_id: user.id).delete_all
    ExternalIdentity.where(user_id: user.id).delete_all
    UserExternalCredential.where(user_id: user.id).delete_all
    account = user.account
    user.destroy
    account&.destroy
  end

  def other_connection
    result = nil
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = yield
      end
    end.join
    result
  end

  def gate_revocation!(world)
    gates = Queue.new
    world.bodies[:revoke_handler] = lambda do |request|
      token = Rack::Utils.parse_nested_query(request.body.to_s)['token']
      box = Queue.new
      gates << [token, box]
      box.pop == :ok ? atproto_json({}) : { status: 500, body: 'nope' }
    end
    gates
  end

  def spawn_disconnect(user, identity, dns)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: dns)
      end
    end
  end

  def take_gate(gates)
    Timeout.timeout(15) { gates.pop }
  end

  def refresh_token_for(user, identity)
    revealed = nil
    credential = UserExternalCredential.find(identity.credential_id)
    UserCredentialVault.with_credential(owner: user, credential: credential, provider: 'bluesky', purpose: 'identity', credential_type: 'oauth_session') do |payload|
      revealed = payload.fetch('credentials').fetch('refresh_token')
      :ok
    end
    revealed
  end

  it 'commits the in-flight refresh marker before the token request and does not send it again' do
    user = nil
    user = Fabricate(:user)
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      seen = nil
      world.bodies[:token_handler] = lambda do |request|
        fields = Rack::Utils.parse_nested_query(request.body)
        unless fields['grant_type'] == 'refresh_token'
          next atproto_json(atproto_tokens)
        end

        seen = other_connection { ExternalIdentity.find(identity.id).refresh_started_at }
        raise 'crash-after-refresh-sent'
      end
      travel 5.minutes
      expect do
        ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns)
      end.to raise_error(RuntimeError, /crash-after-refresh-sent/)
      expect(seen).to be_present
      payload = UserExternalCredential.find(identity.credential_id).encrypted_payload
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('refresh_unacknowledged')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)
      expect(UserExternalCredential.find(identity.credential_id).encrypted_payload).to eq(payload)
      expect(identity.reload.refresh_started_at).to be_present
      expect(identity.status).to eq('reauthentication_required')
    end
  ensure
    travel_back
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
    Rails.cache.clear
    purge_atproto_user(user)
  end

  it 'commits local disconnect before remote revocation and keeps it after a crash' do
    user = nil
    user = Fabricate(:user)
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      pending = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      seen = {}
      crashed = false
      world.bodies[:revoke_handler] = lambda do |_request|
        if crashed
          next atproto_json({})
        end

        crashed = true
        seen = other_connection do
          row = ExternalIdentity.find(identity.id)
          {
            status: row.status,
            disconnected_at: row.disconnected_at,
            revoked_at: UserExternalCredential.find(row.credential_id).revoked_at,
          }
        end
        raise 'crash-during-revoke'
      end
      expect do
        ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
      end.to raise_error(RuntimeError, /crash-during-revoke/)
      expect(seen[:status]).to eq('disconnected')
      expect(seen[:disconnected_at]).to be_present
      expect(seen[:revoked_at]).to be_present
      expect(identity.reload.status).to eq('disconnected')
      expect(identity.revocation_state).to eq('not_attempted')
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
      expect(atproto_error { finish_atproto!(user: user, state: pending[:state], dns: world.dns) }.code).to eq('stale_callback')
      expect(identity.reload.status).to eq('disconnected')
      expect(identity.credential.reload.revoked_at).to be_present
    end
  ensure
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
    Rails.cache.clear
    purge_atproto_user(user)
  end

  it 'keeps the newer session result when the previous revocation response arrives last' do
    user = nil
    user = Fabricate(:user)
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      first_token = refresh_token_for(user, identity)
      gates = gate_revocation!(world)
      thread_a = spawn_disconnect(user, identity, world.dns)
      token_a, box_a = take_gate(gates)
      expect(token_a).to eq(first_token)

      travel 2.seconds
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      reconnected = finish_atproto!(user: user, state: started[:state], dns: world.dns)
      second_token = refresh_token_for(user, reconnected)
      thread_b = spawn_disconnect(user, identity, world.dns)
      token_b, box_b = take_gate(gates)
      expect(token_b).to eq(second_token)

      box_b << :ok
      expect(thread_b.value.revocation_state).to eq('remote_revoked')
      stamp = identity.reload.disconnected_at
      box_a << :fail
      thread_a.value
      row = identity.reload
      expect(row.revocation_state).to eq('remote_revoked')
      expect(row.disconnected_at).to eq(stamp)
      expect(UserExternalCredential.find(row.credential_id).revoked_at).to be_present
    end
  ensure
    travel_back
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
    Rails.cache.clear
    purge_atproto_user(user)
  end

  it 'keeps the newer session result when the previous revocation response arrives first' do
    user = nil
    user = Fabricate(:user)
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      gates = gate_revocation!(world)
      thread_a = spawn_disconnect(user, identity, world.dns)
      _token_a, box_a = take_gate(gates)

      travel 2.seconds
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      reconnected = finish_atproto!(user: user, state: started[:state], dns: world.dns)
      thread_b = spawn_disconnect(user, identity, world.dns)
      _token_b, box_b = take_gate(gates)

      box_a << :fail
      thread_a.value
      expect(identity.reload.revocation_state).to eq('not_attempted')
      box_b << :ok
      expect(thread_b.value.revocation_state).to eq('remote_revoked')
      expect(identity.reload.revocation_state).to eq('remote_revoked')
      expect(identity.oauth_session_stamp).to eq(reconnected.reload.oauth_session_stamp)
    end
  ensure
    travel_back
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
    Rails.cache.clear
    purge_atproto_user(user)
  end
end
