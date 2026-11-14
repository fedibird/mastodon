# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/post_draft_max_snapshot')

describe 'P0 composer snapshots' do
  def load_snapshot(name)
    JSON.parse(Rails.root.join('spec/fixtures/post_drafts', "#{name}.json").read)
  end

  def normalize(raw)
    PostDrafts::Payload.normalize(raw, owner_account_id: raw.fetch('account_id'), client_uuid: raw.fetch('client_draft_uuid'))
  end

  %w(primary hashtag audience long-ja long-en).each do |name|
    it "normalizes the #{name} snapshot from snapshotComposerDraft" do
      raw = load_snapshot(name)
      stored = normalize(raw)

      expect(stored['input']['text']).to eq raw['input']['text']
      expect(stored['input']['media']).to eq []
      expect(stored['content_hash']).to eq raw['content_hash']
      expect(stored['input']['sender']['id']).to eq raw['input']['sender']['id']
    end
  end
end

describe 'P0 composer snapshots', 'protocol audience' do
  def load_snapshot(name)
    JSON.parse(Rails.root.join('spec/fixtures/post_drafts', "#{name}.json").read)
  end

  def normalize(raw)
    PostDrafts::Payload.normalize(raw, owner_account_id: raw.fetch('account_id'), client_uuid: raw.fetch('client_draft_uuid'))
  end

  it 'keeps a null audience from the primary composer' do
    stored = normalize(load_snapshot('primary'))

    expect(stored.dig('input', 'context', 'protocol', 'activity_pub', 'audience')).to be_nil
  end

  it 'keeps an audience record nested under activity_pub' do
    stored = normalize(load_snapshot('audience'))
    audience = stored.dig('input', 'context', 'protocol', 'activity_pub', 'audience')

    expect(audience['accountId']).to eq '456'
    expect(audience['acct']).to eq 'group@mitra.example'
  end

  %w(long-ja long-en).each do |name|
    it "stores 10000 characters of #{name} with context and style and no media" do
      raw = load_snapshot(name)
      stored = normalize(raw)

      expect(raw['input']['text'].length).to eq 10_000
      expect(stored['input']['text']).to eq raw['input']['text']
      expect(stored['input']['media']).to eq []
      expect(stored['input']['context']['key']).to be_present
      expect(stored['input']['user_posting_style']['usage_mode']).to eq 'keep'
    end
  end
end

describe 'P0 composer snapshots', 'payload budget' do
  let(:user) { Fabricate(:user) }

  it 'stores the largest legal snapshot under the same limit as the database check' do
    raw = PostDraftMaxSnapshot.request_body
    raw['account_id'] = user.account_id.to_s
    expect(JSON.generate(raw).bytesize).to be <= PostDrafts::Payload::MAX_BYTES

    created = PostDrafts::Store.new(user.account).create(client_uuid: PostDraftMaxSnapshot::UUID, payload: raw)
    expect(created.status).to eq :created

    stored_bytes = PostDraft.where(id: created.draft.id).pick(Arel.sql('octet_length(payload::text)'))
    definition = ActiveRecord::Base.connection.select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'post_drafts_shape'")

    expect(stored_bytes.to_i).to eq PostDrafts::Payload::MAX_BYTES
    expect(definition).to include(PostDrafts::Payload::MAX_BYTES.to_s)
    expect(created.draft.payload.dig('input', 'text').length).to eq PostDrafts::Payload::TEXT_MAX
    expect(created.draft.payload.dig('input', 'media')).to eq []
  end
end
