# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountsIndex do
  # 46d05ea6e8 defined this normalizer and pointed actor_type at it.
  # AccountSearchService queries the lowercase term "group", while the column
  # stores Person/Group/Service. A later settings edit removed the normalizer
  # block and left the field reference, so creating the index raises
  # mapper_parsing_exception. This does not create or reindex a cluster.
  it 'defines the keyword normalizer that actor_type uses' do
    analysis = AccountsIndex.settings_hash.dig(:settings, :analysis)
    normalizer = analysis.dig(:normalizer, :keyword)
    expect(normalizer).to include(type: 'custom')
    expect(normalizer[:filter]).to eq %w(lowercase asciifolding cjk_width)

    actor_type = AccountsIndex.mappings_hash.dig(:mappings, :properties, :actor_type)
    expect(actor_type).to include(type: 'keyword', normalizer: 'keyword')
    expect(analysis[:analyzer]).not_to have_key(:keyword)
  end
end
