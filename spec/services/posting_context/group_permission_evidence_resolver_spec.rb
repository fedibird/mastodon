# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::GroupPermissionEvidenceResolver do
  subject { described_class.new.call(affiliations, definitions) }

  let(:allowed_create) do
    {
      status: 'allowed',
      source: 'fep-5219',
      via_relationship: via,
      authority: 'protocol',
    }
  end
  let(:unknown_permission) do
    {
      status: 'unknown',
      source: 'fep-5219',
      via_relationship: nil,
      authority: 'protocol',
    }
  end
  let(:via) { 'trusted-poster' }
  let(:affiliations) { fresh_affiliations(via) }
  let(:definitions) { fresh_definitions(can_create: via) }

  def fresh_affiliations(*relationships)
    {
      snapshot_status: 'fresh',
      relationships: relationships.map { |relationship| { relationship: relationship, affiliation_uri: nil } },
    }
  end

  def fresh_definitions(can_create: nil, can_view: nil)
    {
      snapshot_status: 'fresh',
      can_create: can_create,
      can_view: can_view,
    }
  end

  it 'allows create when a fresh custom affiliation matches canCreate' do
    expect(subject[:create]).to eq allowed_create
    expect(subject[:view]).to eq unknown_permission
  end

  it 'leaves create unknown when the definition snapshot has no canCreate' do
    result = described_class.new.call(fresh_affiliations('trusted-poster'), fresh_definitions)

    expect(result[:create]).to eq unknown_permission
  end

  it 'leaves a fresh admin affiliation unknown when canCreate is absent' do
    result = described_class.new.call(fresh_affiliations('admin'), fresh_definitions)

    expect(result[:create]).to eq unknown_permission
  end

  it 'allows create when canCreate names admin and the viewer has that affiliation' do
    result = described_class.new.call(fresh_affiliations('admin'), fresh_definitions(can_create: 'admin'))

    expect(result[:create]).to eq(allowed_create.merge(via_relationship: 'admin'))
  end

  it 'does not treat a different default affiliation as satisfying canCreate' do
    result = described_class.new.call(fresh_affiliations('admin'), fresh_definitions(can_create: 'member'))

    expect(result[:create]).to eq unknown_permission
  end

  it 'does not case-fold the published affiliation identifier' do
    result = described_class.new.call(fresh_affiliations('Admin'), fresh_definitions(can_create: 'admin'))

    expect(result[:create]).to eq unknown_permission
  end

  it 'allows create via the affiliation canCreate names when several are present' do
    result = described_class.new.call(
      fresh_affiliations('role-a', 'role-b'),
      fresh_definitions(can_create: 'role-b')
    )

    expect(result[:create]).to eq(allowed_create.merge(via_relationship: 'role-b'))
  end

  it 'leaves create unknown when the permission definition is stale' do
    result = described_class.new.call(
      fresh_affiliations('trusted-poster'),
      { snapshot_status: 'stale', can_create: 'trusted-poster', can_view: nil }
    )

    expect(result[:create]).to eq unknown_permission
  end

  it 'leaves create unknown when the affiliation snapshot is stale' do
    result = described_class.new.call(
      { snapshot_status: 'stale', relationships: [{ relationship: 'trusted-poster', affiliation_uri: nil }] },
      fresh_definitions(can_create: 'trusted-poster')
    )

    expect(result[:create]).to eq unknown_permission
  end

  %w(unfetched unavailable).each do |snapshot_status|
    it "leaves create unknown when the affiliation snapshot is #{snapshot_status}" do
      result = described_class.new.call(
        { snapshot_status: snapshot_status, relationships: [] },
        fresh_definitions(can_create: 'trusted-poster')
      )

      expect(result[:create]).to eq unknown_permission
    end

    it "leaves create unknown when the permission definition is #{snapshot_status}" do
      result = described_class.new.call(
        fresh_affiliations('trusted-poster'),
        { snapshot_status: snapshot_status, can_create: 'trusted-poster', can_view: nil }
      )

      expect(result[:create]).to eq unknown_permission
    end
  end

  %w(fresh stale unfetched unavailable).each do |snapshot_status|
    it "allows create via none when canCreate is none and the affiliation snapshot is #{snapshot_status}" do
      result = described_class.new.call(
        { snapshot_status: snapshot_status, relationships: [] },
        fresh_definitions(can_create: 'none')
      )

      expect(result[:create]).to eq(allowed_create.merge(via_relationship: 'none'))
    end

    it "allows view via none when canView is none and the affiliation snapshot is #{snapshot_status}" do
      result = described_class.new.call(
        { snapshot_status: snapshot_status, relationships: [] },
        fresh_definitions(can_view: 'none')
      )

      expect(result[:view]).to eq(allowed_create.merge(via_relationship: 'none'))
      expect(result[:create]).to eq unknown_permission
    end
  end

  it 'leaves create unknown when canCreate is none but the definition snapshot is stale' do
    result = described_class.new.call(
      fresh_affiliations,
      { snapshot_status: 'stale', can_create: 'none', can_view: nil }
    )

    expect(result[:create]).to eq unknown_permission
  end

  it 'leaves view unknown when canView is none but the definition snapshot is stale' do
    result = described_class.new.call(
      fresh_affiliations,
      { snapshot_status: 'stale', can_create: nil, can_view: 'none' }
    )

    expect(result[:view]).to eq unknown_permission
  end

  it 'allows view only from canView' do
    result = described_class.new.call(
      fresh_affiliations('member'),
      fresh_definitions(can_view: 'member')
    )

    expect(result[:view]).to eq(unknown_permission.merge(status: 'allowed', via_relationship: 'member'))
    expect(result[:create]).to eq unknown_permission
  end
end
