# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::TagSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        tag,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:tag) { Fabricate(:tag, name: 'foo') }

  it 'keeps returning the raw name even when display_name is set' do
    tag.update!(display_name: 'FOO')

    expect(json[:name]).to eq 'foo'
    expect(json).not_to have_key(:trendable)
    expect(json).not_to have_key(:usable)
    expect(json).not_to have_key(:listable)
    expect(json).not_to have_key(:requires_review)
  end
end
