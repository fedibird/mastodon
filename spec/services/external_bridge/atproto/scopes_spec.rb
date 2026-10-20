# frozen_string_literal: true

require 'rails_helper'

describe ExternalBridge::Atproto::Scopes do
  it 'requests only atproto when the server advertises a subset or transition:generic' do
    expect(described_class.choose(%w(atproto))).to eq(['atproto'])
    expect(described_class.choose(%w(atproto repo:app.bsky.feed.like))).to eq(['atproto'])
    expect(described_class.choose(%w(atproto transition:generic))).to eq(['atproto'])
    expect(described_class.choose(described_class::IDENTITY + described_class.upgrade_candidates)).to eq(['atproto'])
    expect { described_class.choose(%w(transition:generic repo:app.bsky.feed.post)) }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('unsupported_scopes') }
  end

  it 'keeps repository scopes for a later explicit upgrade and rejects a wider grant' do
    expect(described_class.upgrade_candidates).to eq(%w(repo:app.bsky.feed.like repo:app.bsky.feed.repost repo:app.bsky.feed.post))
    granted, partial = described_class.accept!(%w(atproto repo:app.bsky.feed.post), 'atproto')
    expect(granted).to eq(['atproto'])
    expect(partial).to be(true)
    expect { described_class.accept!(['atproto'], 'atproto repo:app.bsky.feed.like') }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('unsupported_scopes') }
    expect { described_class.accept!(['atproto'], 'atproto transition:generic') }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('unsupported_scopes') }
  end
end
