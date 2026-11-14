# frozen_string_literal: true

require 'rails_helper'

describe 'post draft storage quota' do
  let(:user) { Fabricate(:user) }
  let(:store) { PostDrafts::Store.new(user.account) }

  it 'stores a snapshot on the byte budget and rejects one extra byte' do
    uuid = '12121212-1212-4121-8121-121212121212'
    created = store.create(client_uuid: uuid, payload: PostDraftByteBudget.under(account_id: user.account_id, uuid: uuid))
    stored = PostDraft.where(id: created.draft.id).pick(Arel.sql('octet_length(payload::text)')).to_i
    definition = ActiveRecord::Base.connection.select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'post_drafts_shape'")
    validated = ActiveRecord::Base.connection.select_value("SELECT convalidated FROM pg_constraint WHERE conname = 'post_drafts_shape'")

    expect(created.status).to eq :created
    expect(stored).to be <= PostDrafts::Payload::MAX_BYTES
    expect(stored).to be >= PostDrafts::Payload::MAX_BYTES - 16
    expect(definition).to include(PostDrafts::Payload::MAX_BYTES.to_s)
    expect(validated).to be true

    rejected = store.create(
      client_uuid: '13131313-1313-4131-8131-131313131313',
      payload: PostDraftByteBudget.over(account_id: user.account_id, uuid: '13131313-1313-4131-8131-131313131313')
    )

    expect(rejected.status).to eq :invalid
    expect(rejected.error.errors.first).to include('code' => 'too_large', 'key' => 'payload', 'limit' => PostDrafts::Payload::MAX_BYTES)
    expect(PostDraft.where(account_id: user.account_id).count).to eq 1
  end

  it 'keeps every draft when the 100th near-limit row fills the account' do
    payload = PostDraftByteBudget.under(account_id: user.account_id, uuid: '14141414-1414-4141-8141-141414141414')
    PostDraft::LIMIT.times do |index|
      result = store.create(client_uuid: format('15151515-1515-4151-8151-%012x', index), payload: payload)
      expect(result.status).to eq :created
    end

    blocked = store.create(client_uuid: '16161616-1616-4161-8161-161616161616', payload: payload)
    rows = PostDraft.where(account_id: user.account_id)
    total = rows.pick(Arel.sql('coalesce(sum(octet_length(payload::text)), 0)')).to_i

    expect(blocked.status).to eq :limit
    expect(rows.count).to eq PostDraft::LIMIT
    expect(total).to be <= PostDraft::LIMIT * PostDrafts::Payload::MAX_BYTES
    expect(total).to be > (PostDraft::LIMIT - 1) * PostDrafts::Payload::MAX_BYTES
    expect(rows.pick(Arel.sql('min(octet_length(payload::text))')).to_i).to eq rows.pick(Arel.sql('max(octet_length(payload::text))')).to_i
  end

  it 'rejects a snapshot that fills every field cap' do
    raw = PostDraftMaxSnapshot.request_body
    raw['account_id'] = user.account_id.to_s
    result = store.create(client_uuid: PostDraftMaxSnapshot::UUID, payload: raw)

    expect(result.status).to eq :invalid
    expect(result.error.errors.first['code']).to eq 'too_large'
    expect(PostDraft.where(account_id: user.account_id)).to be_empty
  end
end
