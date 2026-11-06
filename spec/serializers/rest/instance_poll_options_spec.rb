# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Instance poll option limit compatibility' do
  before do
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def max_options(serializer)
    json = ActiveModelSerializers::SerializableResource.new(InstancePresenter.new, serializer: serializer).to_json
    JSON.parse(json).dig('configuration', 'polls', 'max_options')
  end

  it 'reports the baseline maximum when the server setting is lower' do
    allow(Setting).to receive(:poll_max_options).and_return(PollOptionsValidator::MAX_OPTIONS - 1)

    expect(max_options(REST::InstanceSerializer)).to eq(PollOptionsValidator::MAX_OPTIONS)
    expect(max_options(REST::V1::InstanceSerializer)).to eq(PollOptionsValidator::MAX_OPTIONS)
  end

  it 'reports a raised effective maximum consistently in both API versions' do
    configured_limit = PollOptionsValidator::MAX_OPTIONS + 4
    allow(Setting).to receive(:poll_max_options).and_return(configured_limit)

    expect(max_options(REST::InstanceSerializer)).to eq(configured_limit)
    expect(max_options(REST::V1::InstanceSerializer)).to eq(configured_limit)
  end
end
