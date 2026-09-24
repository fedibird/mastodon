# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::InstanceAccountsDimension do
  let(:domain) { 'remote.example' }
  let(:params) { ActionController::Parameters.new(domain: domain) }

  it 'ranks remote accounts by follower count' do
    popular = Fabricate(:account, domain: domain, username: 'popular')
    quiet = Fabricate(:account, domain: domain, username: 'quiet')
    local = Fabricate(:account)
    local.follow!(popular)
    Fabricate(:account).follow!(popular)
    local.follow!(quiet)

    dimension = described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), 10, params)
    expect(dimension.data).to eq [
      { key: 'popular', human_key: 'popular', value: '2' },
      { key: 'quiet', human_key: 'quiet', value: '1' },
    ]
  end
end
