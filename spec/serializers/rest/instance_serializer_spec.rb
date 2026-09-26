# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::InstanceSerializer do
  let(:serialization) { serialized_record_json(record, described_class) }
  let(:record) { InstancePresenter.new }

  def instance_json
    JSON.parse(ActiveModelSerializers::SerializableResource.new(InstancePresenter.new, serializer: described_class).to_json)
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
            accounts: include(max_pinned_statuses: StatusPinValidator::PIN_LIMIT)
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
