# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Fedibird::CapabilityCatalog do
  describe '.legacy' do
    it 'preserves the existing static values and order' do
      allow(Chewy).to receive(:enabled?).and_return(true)

      expect(described_class.legacy).to eq(described_class::LEGACY_CAPABILITIES)
      expect(described_class.legacy).to include(:filter_v2, :status_reference, :emoji_reaction)
    end

    it 'preserves the conditional profile_search extension' do
      allow(Chewy).to receive(:enabled?).and_return(false)
      expect(described_class.legacy.last).to eq(:profile_search)

      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(described_class.legacy).not_to include(:profile_search)
    end

    it 'returns a fresh copy of the legacy array' do
      allow(Chewy).to receive(:enabled?).and_return(true)
      described_class.legacy << :temporary

      expect(described_class.legacy).not_to include(:temporary)
    end
  end

  describe '.instance' do
    it 'does not conflate endpoint support with instance translation configuration' do
      allow(TranslationService).to receive(:configured?).and_return(false)

      info = described_class.instance
      expect(info[:schema_version]).to eq(1)
      expect(info.dig(:rest, :supported)).to include('status_translation')
      expect(info.dig(:rest, :translation)).to eq(instance_enabled: false, viewer_scoped: true)
    end

    it 'reflects instance-level translation configuration without viewer data' do
      allow(TranslationService).to receive(:configured?).and_return(true)

      expect(described_class.instance.dig(:rest, :translation, :instance_enabled)).to be(true)
    end
  end

  describe '.nodeinfo' do
    it 'advertises only software-wide ActivityPub hints' do
      info = described_class.nodeinfo

      expect(info.keys).to contain_exactly(:schema_version, :activitypub)
      expect(info.dig(:activitypub, :supported)).to include('note_references', 'group_actor')
      expect(info.dig(:activitypub, :supported)).not_to include('fep_1b12_audience', 'fep_400e_append')
    end
  end
end
