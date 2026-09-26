# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::ListSerializer do
  def serialize(list)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        list,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'exposes exclusive as false' do
    list = Fabricate(:list, favourite: false)

    expect(serialize(list)[:exclusive]).to be false
  end

  it 'keeps favourite separate from exclusive' do
    list = Fabricate(:list, favourite: true)
    json = serialize(list)

    expect(json[:favourite]).to be true
    expect(json[:exclusive]).to be false
  end
end
