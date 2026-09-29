# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::Admin::EmailDomainBlockSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        email_domain_block,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:email_domain_block) { Fabricate(:email_domain_block, domain: 'example.com') }
  let(:now) { Time.utc(2026, 9, 19, 12, 0, 0) }

  around do |example|
    travel_to(now) { example.run }
  end

  it 'serializes exactly the admin email domain block fields' do
    expect(json.keys).to contain_exactly(:id, :domain, :created_at, :history, :allow_with_approval)
    expect(json[:id]).to eq email_domain_block.id.to_s
    expect(json[:id]).to be_a(String)
    expect(json[:domain]).to eq 'example.com'
    expect(json[:created_at]).to be_present
    expect(json[:allow_with_approval]).to be false
    expect(json).not_to have_key(:parent_id)
    expect(json).not_to have_key(:updated_at)
    expect(json).not_to have_key(:with_dns_records)
    expect(json).not_to have_key(:children)
  end

  it 'serializes allow_with_approval when the block requires approval' do
    email_domain_block.update!(allow_with_approval: true)

    expect(json[:allow_with_approval]).to be true
    expect(json.keys).to contain_exactly(:id, :domain, :created_at, :history, :allow_with_approval)
  end

  it 'serializes seven history days with string counts' do
    expect(json[:history].size).to eq 7
    json[:history].each do |entry|
      expect(entry.keys).to contain_exactly(:day, :accounts, :uses)
      expect(entry[:day]).to be_a(String)
      expect(entry[:accounts]).to be_a(String)
      expect(entry[:uses]).to be_a(String)
    end
  end

  it 'includes recorded signup attempt history' do
    email_domain_block.history.add('192.0.2.1')
    email_domain_block.history.add('192.0.2.1')
    email_domain_block.history.add('192.0.2.2')

    expect(json[:history].first[:uses]).to eq '3'
    expect(json[:history].first[:accounts]).to eq '2'
  end
end
