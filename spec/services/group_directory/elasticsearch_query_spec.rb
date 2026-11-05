# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::ElasticsearchQuery do
  def parsed(params)
    GroupDirectory::Parameters.parse!(params)
  end

  def body_for(params)
    described_class.new(viewer: nil, parsed: parsed(params), limit: 20).request_body(search_after: nil, size: 50)
  end

  it 'builds a filter query and does not pass the user string to query_string' do
    body = body_for(q: '写真サークル', order: 'active')
    dumped = body.to_s

    expect(dumped).not_to include('query_string', 'wildcard', 'regexp', 'terms')
    expect(body[:from]).to be_nil
    expect(body[:search_after]).to be_nil
    expect(body.dig(:sort, 0, :last_status_at)).to include(order: 'desc', missing: '_last')
    expect(body.dig(:sort, 1, :id)).to include(order: 'desc')
    expect(body.dig(:query, :bool, :filter).to_s).to include('text.infix', '写真サークル')
  end

  it 'ANDs 20-character windows for a longer query and sorts new by id' do
    token = "#{'0123456789abcdefghij'}TAIL"
    body = body_for(q: token, order: 'new')
    text = body.dig(:query, :bool, :filter).detect { |clause| clause.dig(:bool, :filter) }
    windows = text[:bool][:filter].map { |clause| clause.dig(:match, 'text.infix', :query) }

    expect(windows).to all(have_attributes(length: 20))
    expect(windows.first).to eq(token[0, 20])
    expect(windows.last).to end_with('TAIL')
    expect(body[:sort]).to eq([{ id: { order: 'desc' } }])
  end

  it 'uses exact terms for a handle and keyword filters for software, language, and scope' do
    handle = body_for(q: '@Walkers@lemmy.example')
    filters = handle.dig(:query, :bool, :filter)
    expect(filters).to include({ term: { username: 'walkers' } }, { term: { domain: 'lemmy.example' } })
    expect(filters.to_s).not_to include('text.infix')

    fedibird = body_for(software: 'fedibird', language: 'unset', scope: 'local')
    expect(fedibird.dig(:query, :bool, :filter)).to include(
      { term: { software_bucket: 'fedibird' } },
      { term: { languages_unset: true } },
      { term: { local: true } }
    )

    other = body_for(software: 'lemmy', language: 'en-us', scope: 'following')
    expect(other.dig(:query, :bool, :filter)).to include(
      { term: { software_name: 'lemmy' } },
      { term: { languages: 'en-US' } }
    )
    expect(other.to_s).not_to include('following', 'terms')
  end

  it 'turns a timed out or broken response into an unavailable search' do
    allow(Chewy.client).to receive(:open_point_in_time).and_return('id' => 'pit-1')
    allow(Chewy.client).to receive(:close_point_in_time).and_return('succeeded' => true)
    query = described_class.new(viewer: nil, parsed: parsed({}), limit: 5)
    allow(Chewy.client).to receive(:search).and_return('timed_out' => true, 'hits' => { 'hits' => [] })
    expect { query.results }.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to eq('elasticsearch timed out')
    }

    allow(Chewy.client).to receive(:search).and_return('hits' => nil)
    expect { query.results }.to raise_error(GroupDirectory::SearchUnavailable)

    allow(Chewy.client).to receive(:search).and_raise(Faraday::ConnectionFailed.new('down'))
    expect { query.results }.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to include('Faraday::ConnectionFailed')
    }
  end
end
