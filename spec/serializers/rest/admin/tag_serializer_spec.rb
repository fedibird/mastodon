# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::Admin::TagSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        tag,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:tag) { Fabricate(:tag, name: 'foo', trendable: true, usable: false, listable: true, reviewed_at: nil) }

  it 'serializes exactly the admin tag fields with a string id' do
    expect(json.keys).to contain_exactly(:id, :name, :url, :history, :trendable, :usable, :requires_review, :listable)
    expect(json[:id]).to eq tag.id.to_s
    expect(json[:id]).to be_a(String)
    expect(json[:url]).to be_present
    expect(json[:history]).to be_an(Array)
    expect(json[:trendable]).to eq true
    expect(json[:usable]).to eq false
    expect(json[:listable]).to eq true
    expect(json[:requires_review]).to eq true
  end

  it 'falls back to the raw name when display_name is nil' do
    expect(tag.attributes['display_name']).to be_nil
    expect(json[:name]).to eq 'foo'
  end

  it 'returns display_name as name when it is set' do
    tag.update!(display_name: 'FOO')

    expect(json[:name]).to eq 'FOO'
  end
end
