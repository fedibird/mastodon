# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::KeywordSubscribesSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        keyword_subscribe,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:keyword_subscribe) do
    Fabricate(
      :keyword_subscribe,
      keyword: 'fediverse',
      exclude_keyword: 'spam',
      ignorecase: true,
      regexp: false,
      ignore_block: false,
      disabled: false
    )
  end

  it 'serializes the current KeywordSubscribe attributes without the removed exclude_home field' do
    expect(json).to include(
      id: keyword_subscribe.id.to_s,
      name: keyword_subscribe.name,
      keyword: 'fediverse',
      exclude_keyword: 'spam',
      ignorecase: true,
      regexp: false,
      ignore_block: false,
      disabled: false
    )
    expect(json).not_to have_key(:exclude_home)
  end
end
