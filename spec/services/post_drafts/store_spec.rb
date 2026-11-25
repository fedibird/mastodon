# frozen_string_literal: true

require 'rails_helper'

describe PostDrafts::Store do
  let(:user) { Fabricate(:user) }
  let(:store) { described_class.new(user.account) }
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }
  let(:other_uuid) { '22222222-2222-4222-8222-222222222222' }

  def payload(text, sender_id: nil)
    body = {
      'schema_version' => 1,
      'media_incomplete' => false,
      'input' => {
        'text' => text,
        'privacy' => 'personal',
        'media' => [],
      },
    }
    body['input']['sender'] = { 'id' => "delegated:#{sender_id}", 'selection_origin' => 'explicit' } if sender_id
    body
  end

  it 'creates one row for a repeated uuid and does not publish it' do
    expect do
      created = store.create(client_uuid: uuid, payload: payload('hello'))
      replay = store.create(client_uuid: uuid, payload: payload('hello'))

      expect(created.status).to eq :created
      expect(created.draft.revision).to eq 1
      expect(replay.status).to eq :existing
      expect(replay.draft.id).to eq created.draft.id
    end.not_to change { [Status.count, ScheduledStatus.count, Notification.count] }

    expect(PostDraft.where(account_id: user.account_id).count).to eq 1
  end

  it 'does not overwrite a different body for the same uuid' do
    created = store.create(client_uuid: uuid, payload: payload('hello'))
    conflict = store.create(client_uuid: uuid, payload: payload('changed'))

    expect(conflict.status).to eq :conflict
    expect(conflict.draft.revision).to eq 1
    expect(conflict.draft.payload.dig('input', 'text')).to eq 'hello'
    expect(created.draft.reload.payload.dig('input', 'text')).to eq 'hello'
  end

  it 'stores the draft on the signed-in account when the sender is someone else' do
    other = Fabricate(:account)
    created = store.create(client_uuid: uuid, payload: payload('hello', sender_id: other.id))

    expect(created.draft.account_id).to eq user.account_id
    expect(created.draft.payload.dig('input', 'sender', 'id')).to eq "delegated:#{other.id}"
    expect(PostDraft.where(account_id: other.id)).to be_empty
  end

  it 'increments the revision only when the expected revision matches' do
    created = store.create(client_uuid: uuid, payload: payload('hello'))
    stale = store.update(created.draft.id, expected_revision: 0, payload: payload('stale'))
    updated = store.update(created.draft.id, expected_revision: 1, payload: payload('next'))
    lost = store.update(created.draft.id, expected_revision: 1, payload: payload('lost'))

    expect(stale.status).to eq :conflict
    expect(updated.status).to eq :updated
    expect(updated.draft.revision).to eq 2
    expect(updated.draft.payload.dig('input', 'text')).to eq 'next'
    expect(lost.status).to eq :conflict
    expect(lost.draft.revision).to eq 2
  end

  it 'returns missing when an update or delete loses the row' do
    created = store.create(client_uuid: uuid, payload: payload('hello'))
    expect(store.destroy(created.draft.id, expected_revision: 1).status).to eq :deleted
    expect(store.update(created.draft.id, expected_revision: 1, payload: payload('later')).status).to eq :missing
    expect(store.destroy(created.draft.id, expected_revision: 1).status).to eq :missing
    expect(store.destroy(created.draft.id, expected_revision: '1').status).to eq :invalid
  end

  it 'keeps a newer revision when an older delete arrives after the update' do
    created = store.create(client_uuid: uuid, payload: payload('hello'))
    updated = store.update(created.draft.id, expected_revision: 1, payload: payload('edited'))
    stale = store.destroy(created.draft.id, expected_revision: 1)

    expect(updated.status).to eq :updated
    expect(stale.status).to eq :conflict
    expect(stale.draft.revision).to eq 2
    expect(created.draft.reload.payload.dig('input', 'text')).to eq 'edited'

    removed = store.destroy(created.draft.id, expected_revision: 2)
    expect(removed.status).to eq :deleted
    expect(PostDraft.where(id: created.draft.id)).to be_empty
  end

  it 'stops at the account cap without deleting an existing draft' do
    stub_const('PostDraft::LIMIT', 1)
    kept = store.create(client_uuid: uuid, payload: payload('kept'))
    blocked = store.create(client_uuid: other_uuid, payload: payload('blocked'))

    expect(kept.status).to eq :created
    expect(blocked.status).to eq :limit
    expect(PostDraft.where(account_id: user.account_id).pluck(:client_uuid)).to eq [uuid]
    expect(store.create(client_uuid: uuid, payload: payload('kept')).status).to eq :existing
  end

  it 'indexes drafts by owner and client uuid, and by owner update time' do
    names = ActiveRecord::Base.connection.indexes(:post_drafts).map(&:name)

    expect(names).to include('index_post_drafts_on_account_id_and_client_uuid', 'index_post_drafts_on_account_updated_at_and_id')
  end

  it 'rejects an unverified media id without inserting a row' do
    result = store.create(client_uuid: uuid, payload: payload('hello').deep_merge('input' => { 'media' => [{ 'id' => '99' }] }))

    expect(result.status).to eq :invalid
    expect(result.error.errors.first['code']).to eq 'media_missing'
    expect(PostDraft.where(account_id: user.account_id)).to be_empty
  end
end
