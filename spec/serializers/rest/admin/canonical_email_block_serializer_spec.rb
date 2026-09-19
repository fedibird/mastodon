# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::Admin::CanonicalEmailBlockSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        canonical_email_block,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:canonical_email_block) { Fabricate(:canonical_email_block, email: 'foo@example.com', reference_account: nil) }

  it 'serializes exactly the Mastodon 4.2 admin canonical email block fields' do
    expect(json.keys).to contain_exactly(:id, :canonical_email_hash)
    expect(json[:id]).to eq canonical_email_block.id.to_s
    expect(json[:id]).to be_a(String)
    expect(json[:canonical_email_hash]).to eq canonical_email_block.canonical_email_hash
    expect(json).not_to have_key(:reference_account_id)
    expect(json).not_to have_key(:created_at)
    expect(json).not_to have_key(:updated_at)
    expect(json).not_to have_key(:email)
  end
end
