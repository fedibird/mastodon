# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::KeywordSubscribesSerializer do
  it 'exposes both matching options' do
    expect(described_class._attributes).to include(:match_hashtags, :match_urls)
  end
end
