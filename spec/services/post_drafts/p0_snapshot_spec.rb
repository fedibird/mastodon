# frozen_string_literal: true

require 'rails_helper'

describe 'P0 composer snapshots' do
  def load_snapshot(name)
    JSON.parse(Rails.root.join('spec/fixtures/post_drafts', "#{name}.json").read)
  end

  def normalize(raw)
    PostDrafts::Payload.normalize(raw, owner_account_id: raw.fetch('account_id'), client_uuid: raw.fetch('client_draft_uuid'))
  end

  %w(primary hashtag audience long-ja long-en paragraphs).each do |name|
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

describe 'P0 composer snapshots', 'body whitespace' do
  def normalize(raw)
    PostDrafts::Payload.normalize(raw, owner_account_id: '42', client_uuid: '66666666-6666-4666-8666-666666666666')
  end

  def with_text(text, **input)
    {
      'schema_version' => 1,
      'input' => { 'text' => text, 'media' => [] }.merge(input.stringify_keys),
    }
  end

  it 'keeps line breaks and tabs in the body' do
    ["1段落目\n\n2段落目", "left\r\nright", "a\tb"].each do |text|
      expect(normalize(with_text(text))['input']['text']).to eq text
    end
  end

  it 'rejects NUL and ESC in the body and a line break in the content warning' do
    ["a\u0000b", "a\eb"].each do |text|
      expect { normalize(with_text(text)) }.to raise_error(PostDrafts::Payload::Invalid) { |error|
        expect(error.errors.first).to include('code' => 'invalid_format', 'key' => 'input.text')
      }
    end

    expect { normalize(with_text('hello', spoiler_text: "warn\ning")) }.to raise_error(PostDrafts::Payload::Invalid) { |error|
      expect(error.errors.first).to include('code' => 'invalid_format', 'key' => 'input.spoiler_text')
    }
    expect { normalize(with_text("#{'a' * 10_000}\n")) }.to raise_error(PostDrafts::Payload::Invalid) { |error|
      expect(error.errors.first).to include('code' => 'too_long', 'key' => 'input.text')
    }
  end
end
