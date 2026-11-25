# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostDrafts::WebSession do # rubocop:disable Metrics/BlockLength
  def admit!(user)
    Setting.post_draft_sync = true
    Setting.post_draft_sync_testers = user.id.to_s
  end

  def session_for(user)
    Fabricate(:session_activation, user: user, session_id: SecureRandom.hex)
  end

  it 'leaves an ordinary web session unchanged while sync is off' do
    user = Fabricate(:user)
    activation = session_for(user)
    token = activation.access_token
    external = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read write')

    result = described_class.prepare(activation)

    expect(result.enabled).to be false
    expect(result.reason).to eq 'disabled'
    expect(token.reload.scopes.to_s).to eq 'read write follow'
    expect(token.revoked_at).to be_nil
    expect(external.reload.scopes.to_s).to eq 'read write'
    expect(external.revoked_at).to be_nil
  end

  it 'does not admit a signed-in user who is not on the list' do
    user = Fabricate(:user)
    Setting.post_draft_sync = true
    activation = session_for(user)

    result = described_class.prepare(activation)

    expect(result.enabled).to be false
    expect(result.reason).to eq 'not_admitted'
    expect(activation.reload.access_token.scopes.to_s).to eq 'read write follow'
    expect(activation.access_token.revoked_at).to be_nil
  end

  it 'adds the draft scopes to the current web session only' do
    user = Fabricate(:user)
    activation = session_for(user)
    previous = activation.access_token
    other_session = session_for(user)
    other_token = other_session.access_token
    application = Fabricate(:application, scopes: 'read write')
    external = Fabricate(:accessible_access_token, resource_owner_id: user.id, application: application, scopes: 'read write')
    admit!(user)

    result = described_class.prepare(activation)

    expect(result.enabled).to be true
    expect(result.reason).to be_nil
    replacement = activation.reload.access_token
    expect(replacement.id).not_to eq previous.id
    expect(replacement.scopes.to_s).to eq 'read write follow read:post_drafts write:post_drafts'
    expect(replacement.resource_owner_id).to eq user.id
    expect(previous.reload.revoked_at).to be_present
    expect(other_token.reload.scopes.to_s).to eq 'read write follow'
    expect(other_token.revoked_at).to be_nil
    expect(external.reload.scopes.to_s).to eq 'read write'
    expect(external.revoked_at).to be_nil
    expect(application.reload.scopes.to_s).not_to include('post_drafts')
  end

  it 'does not rotate a session that already has the draft scopes' do
    user = Fabricate(:user)
    admit!(user)
    activation = session_for(user)
    described_class.prepare(activation)
    current = activation.reload.access_token

    result = described_class.prepare(activation)

    expect(result.enabled).to be true
    expect(activation.reload.access_token.id).to eq current.id
    expect(current.reload.revoked_at).to be_nil
  end

  it 'mints the draft scopes on a new web session for an admitted user' do
    user = Fabricate(:user)
    admit!(user)

    activation = session_for(user)

    expect(activation.access_token.scopes.to_s).to eq 'read write follow read:post_drafts write:post_drafts'
  end

  it 'keeps the historical scopes on a new web session when the user is not admitted' do
    activation = session_for(Fabricate(:user))

    expect(activation.access_token.scopes.to_s).to eq 'read write follow'
  end

  it 'does not mint a replacement for a revoked web token' do
    user = Fabricate(:user)
    admit!(user)
    activation = session_for(user)
    activation.access_token.revoke

    result = described_class.prepare(activation)

    expect(result.enabled).to be false
    expect(result.reason).to eq 'missing_scope'
    expect(activation.reload.access_token.revoked_at).to be_present
  end
end
