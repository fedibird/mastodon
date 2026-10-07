# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::GroupPermissionEvidenceResolver do
  let(:allowed_create) do
    {
      status: 'allowed',
      source: 'fep-5219',
      via_relationship: 'admin',
      authority: 'protocol',
    }
  end
  let(:unknown_create) do
    {
      status: 'unknown',
      source: 'fep-5219',
      via_relationship: nil,
      authority: 'protocol',
    }
  end

  it 'treats a fresh standard admin affiliation as positive create evidence' do
    evidence = {
      snapshot_status: 'fresh',
      relationships: [
        { relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1' },
      ],
    }

    expect(described_class.new.call(evidence)).to eq(create: allowed_create)
  end

  %w(Admin ADMIN administrator https://example/roles/admin).each do |relationship|
    it "leaves #{relationship} unknown" do
      evidence = {
        snapshot_status: 'fresh',
        relationships: [
          { relationship: relationship, affiliation_uri: 'https://group.example/relationships/1' },
        ],
      }

      expect(described_class.new.call(evidence)).to eq(create: unknown_create)
    end
  end

  it 'leaves a custom relationship unknown' do
    evidence = {
      snapshot_status: 'fresh',
      relationships: [
        { relationship: 'trusted-poster', affiliation_uri: nil },
      ],
    }

    expect(described_class.new.call(evidence)).to eq(create: unknown_create)
  end

  it 'allows create when admin is present among other relationships' do
    evidence = {
      snapshot_status: 'fresh',
      relationships: [
        { relationship: 'trusted-poster', affiliation_uri: 'https://group.example/relationships/2' },
        { relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1' },
        { relationship: 'custom', affiliation_uri: 'https://vocab.example/roles/publisher' },
      ],
    }

    expect(described_class.new.call(evidence)).to eq(create: allowed_create)
  end

  it 'does not use a stale admin row as positive evidence' do
    evidence = {
      snapshot_status: 'stale',
      relationships: [
        { relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1' },
      ],
    }

    expect(described_class.new.call(evidence)).to eq(create: unknown_create)
  end

  it 'leaves a fresh empty snapshot unknown' do
    evidence = {
      snapshot_status: 'fresh',
      relationships: [],
    }

    expect(described_class.new.call(evidence)).to eq(create: unknown_create)
  end

  %w(unfetched unavailable).each do |snapshot_status|
    it "leaves an #{snapshot_status} snapshot unknown" do
      evidence = {
        snapshot_status: snapshot_status,
        relationships: [],
      }

      expect(described_class.new.call(evidence)).to eq(create: unknown_create)
    end
  end
end
