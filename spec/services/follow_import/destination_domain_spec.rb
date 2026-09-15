# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DestinationDomain do
  let(:local_domain) { TagManager.instance.normalize_domain(Rails.configuration.x.local_domain) }

  it 'normalizes a remote acct and drops the username' do
    expect(described_class.from_acct('Alice@EXAMPLE.COM')).to eq 'example.com'
  end

  it 'treats a bare local acct as the local domain' do
    expect(described_class.from_acct('alice')).to eq local_domain
  end

  it 'treats an explicit local acct as the local domain' do
    expect(described_class.from_acct("alice@#{Rails.configuration.x.local_domain.upcase}")).to eq local_domain
  end

  it 'returns nil for a blank username' do
    expect(described_class.from_acct('@example.com')).to be_nil
    expect(described_class.from_acct('')).to be_nil
  end
end
