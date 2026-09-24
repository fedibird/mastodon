# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::SoftwareVersionsDimension do
  subject(:dimension) { described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), nil, nil) }

  before do
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:execute).with('SELECT VERSION()').and_return([{ 'version' => 'PostgreSQL 14.5 on x86_64' }])
    allow(dimension).to receive(:redis_info).and_return({ 'redis_version' => '7.0.0' })
  end

  it 'omits the search engine when Chewy is disabled' do
    allow(Chewy).to receive(:enabled?).and_return(false)

    expect(dimension.data.map { |row| row[:key] }).to eq %w(mastodon ruby postgresql redis)
    expect(dimension.data.first[:human_key]).to eq 'Mastodon'
  end

  it 'labels OpenSearch when the client reports that distribution' do
    client = double(info: { 'version' => { 'number' => '2.11.0', 'distribution' => 'opensearch' } })
    allow(Chewy).to receive(:enabled?).and_return(true)
    allow(Chewy).to receive(:client).and_return(client)

    search = dimension.data.find { |row| row[:key] == 'elasticsearch' }
    expect(search).to include(human_key: 'OpenSearch', value: '2.11.0')
  end

  it 'labels Elasticsearch otherwise' do
    client = double(info: { 'version' => { 'number' => '8.8.0' } })
    allow(Chewy).to receive(:enabled?).and_return(true)
    allow(Chewy).to receive(:client).and_return(client)

    search = dimension.data.find { |row| row[:key] == 'elasticsearch' }
    expect(search).to include(human_key: 'Elasticsearch', value: '8.8.0')
  end

  it 'omits the search engine when the client cannot connect' do
    client = double
    allow(client).to receive(:info).and_raise(Faraday::ConnectionFailed.new('down'))
    allow(Chewy).to receive(:enabled?).and_return(true)
    allow(Chewy).to receive(:client).and_return(client)

    expect(dimension.data.map { |row| row[:key] }).to eq %w(mastodon ruby postgresql redis)
  end
end
