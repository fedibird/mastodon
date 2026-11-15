# frozen_string_literal: true

require 'rails_helper'

describe PostDrafts::Payload do
  let(:owner_id) { '42' }
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }

  def normalize(payload)
    described_class.normalize(payload, owner_account_id: owner_id, client_uuid: uuid)
  end

  def input(text = 'hello', extra = {})
    {
      'schema_version' => 1,
      'input' => { 'text' => text, 'privacy' => 'personal' }.merge(extra),
    }
  end

  it 'keeps a personal draft and reports that media was not part of the body' do
    stored = normalize(input('hello'))

    expect(stored['schema_version']).to eq 1
    expect(stored['input']['text']).to eq 'hello'
    expect(stored['input']['privacy']).to eq 'personal'
    expect(stored['input']['media']).to eq []
    expect(stored).not_to have_key('account_id')
  end

  it 'treats a repeated body as the same payload and a different body as different' do
    left = normalize(input('hello').merge('saved_at' => '2026-11-14T00:00:00Z', 'account_id' => owner_id, 'client_draft_uuid' => uuid))
    right = normalize(input('hello'))

    expect(described_class.same?(left, right)).to be true
    expect(described_class.same?(left, normalize(input('changed')))).to be false
  end

  it 'rejects another account, an unknown schema, html, and a media id' do
    expect { normalize(input('hello').merge('account_id' => '7')) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'owner_mismatch' }
    expect { normalize(input('hello').merge('schema_version' => 2)) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'unsupported_schema' }
    expect { normalize(input('hello').merge('html' => '<p>no</p>')) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'unknown_field' }
    expect { normalize(input('hello', 'media' => [{ 'id' => '9' }])) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'media_not_retained' }
  end

  it 'rejects a token field nested in the input' do
    expect { normalize(input('hello', 'access_token' => 'secret')) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'forbidden_field' }
  end

  it 'accepts only a lowercase uuid' do
    expect(described_class.client_uuid!(uuid.upcase)).to eq uuid
    expect { described_class.client_uuid!('draft-1') }.to raise_error(described_class::Invalid)
  end
end

describe PostDrafts::Payload, 'P0 snapshot shapes' do
  let(:owner_id) { '42' }
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }

  def normalize(payload)
    described_class.normalize(payload, owner_account_id: owner_id, client_uuid: uuid)
  end

  def snapshot(content_hash)
    {
      'schema_version' => 1,
      'composer_id' => 'portable:hashtag-column:日本語',
      'content_hash' => content_hash,
      'account_id' => owner_id,
      'client_draft_uuid' => uuid,
      'saved_at' => '2026-11-14T00:00:00.000Z',
      'input' => {
        'text' => 'こんにちは',
        'privacy' => 'personal',
        'sender' => { 'id' => 'local:42', 'selection_origin' => 'default' },
        'context' => {
          'key' => 'builtin:hashtag:日本語',
          'source' => { 'id' => 'builtin:hashtag-timeline', 'revision' => 1 },
        },
        'surface' => { 'kind' => 'hashtag', 'key' => '日本語' },
        'user_posting_style' => {
          'usage_mode' => 'usual',
          'selection_kind' => 'pending',
          'destination_status' => 'idle',
          'manual_values' => { 'spoilerText' => 'あ' * 500 },
        },
      },
    }
  end

  it 'keeps a sender identity, the client content hash, and a hashtag context' do
    content_hash = '{"input":{"text":"こんにちは"},"media_incomplete":false}'
    stored = normalize(snapshot(content_hash))

    expect(stored['content_hash']).to eq content_hash
    expect(stored['composer_id']).to eq 'portable:hashtag-column:日本語'
    expect(stored['input']['sender']).to eq('id' => 'local:42', 'selection_origin' => 'default')
    expect(stored['input']['context']['source']['id']).to eq 'builtin:hashtag-timeline'
    expect(stored['input']['context']['key']).to eq 'builtin:hashtag:日本語'
    expect(stored['input']['user_posting_style']['manual_values']['spoilerText'].length).to eq 500
    expect(stored).not_to have_key('account_id')
    expect(stored).not_to have_key('saved_at')
  end

  it 'rejects a bare account id as a sender and a control character in the content hash' do
    expect { normalize(snapshot('hash').merge('input' => { 'text' => 'hello', 'privacy' => 'personal', 'sender' => { 'id' => '42' } })) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'invalid_reference' }
    expect { normalize(snapshot('hash').merge('input' => { 'text' => 'hello', 'privacy' => 'personal', 'sender' => { 'id' => 'group:42' } })) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'invalid_reference' }
    expect { normalize(snapshot("hello\n")) }.to raise_error(described_class::Invalid) { |error| expect(error.errors.first['code']).to eq 'invalid_format' }
  end
end
