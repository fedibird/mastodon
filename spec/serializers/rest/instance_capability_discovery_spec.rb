# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::InstanceSerializer do
  before do
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def instance_json
    JSON.parse(ActiveModelSerializers::SerializableResource.new(InstancePresenter.new, serializer: described_class).to_json)
  end

  describe 'fedibird capability discovery' do
    it 'advertises a versioned REST/AP catalog without viewer state' do
      info = instance_json['fedibird']

      expect(info['schema_version']).to eq(1)
      expect(info.dig('rest', 'supported')).to include('emoji_reactions', 'status_references', 'filters_v2', 'timeline_seek')
      expect(info.dig('activitypub', 'supported')).to include('emoji_react', 'note_references', 'legacy_quote_uri')
      expect(info.dig('rest', 'translation', 'viewer_scoped')).to be(true)
    end

    it 'distinguishes instance translation configuration from per-user support' do
      allow(TranslationService).to receive(:configured?).and_return(false)
      expect(instance_json.dig('fedibird', 'rest', 'translation', 'instance_enabled')).to be(false)

      allow(TranslationService).to receive(:configured?).and_return(true)
      expect(instance_json.dig('fedibird', 'rest', 'translation', 'instance_enabled')).to be(true)
    end
  end
end
