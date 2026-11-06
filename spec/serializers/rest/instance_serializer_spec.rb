# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::InstanceSerializer do
  let(:serialization) { serialized_record_json(record, described_class) }
  let(:record) { InstancePresenter.new }

  def serialized_record_json(record, serializer)
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)

    JSON.parse(ActiveModelSerializers::SerializableResource.new(record, serializer: serializer).to_json)
  end

  def instance_json
    serialized_record_json(InstancePresenter.new, described_class)
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

  describe 'usage' do
    it 'returns recent usage data' do
      expect(serialization['usage']).to eq({ 'users' => { 'active_month' => 0 } })
    end
  end

  describe 'configuration' do
    it 'returns the VAPID public key' do
      expect(serialization['configuration']['vapid']).to eq({
        'public_key' => Rails.configuration.x.vapid_public_key,
      })
    end

    it 'returns the max pinned statuses limit' do
      expect(serialization.deep_symbolize_keys)
        .to include(
          configuration: include(
            accounts: include(max_pinned_statuses: [StatusPinValidator::LIMIT, Setting.pins_max].min)
          )
        )
    end

    it 'exposes the configured status page URL' do
      previous = Setting.status_page_url
      Setting.status_page_url = 'https://status.example.com'

      expect(instance_json['configuration']['urls']['status']).to eq 'https://status.example.com'
    ensure
      Setting.status_page_url = previous
    end

    it 'keeps a blank status page URL blank' do
      previous = Setting.status_page_url
      Setting.status_page_url = ''

      expect(instance_json['configuration']['urls']['status']).to eq ''
    ensure
      Setting.status_page_url = previous
    end
  end
end
