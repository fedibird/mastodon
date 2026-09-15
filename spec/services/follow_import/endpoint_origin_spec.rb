# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::EndpointOrigin do
  it 'returns scheme, host, and non-default port without the path' do
    expect(described_class.from_url('https://example.social:8443/users/alice/inbox')).to eq 'https://example.social:8443'
  end

  it 'normalizes the host and omits a default https port' do
    expect(described_class.from_url('https://EXAMPLE.social/inbox')).to eq 'https://example.social'
  end

  it 'returns nil for blank or invalid URLs' do
    expect(described_class.from_url(nil)).to be_nil
    expect(described_class.from_url('not a url')).to be_nil
  end
end
