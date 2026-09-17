# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LanguagesHelper do
  it 'autoloads supported locales including Japanese' do
    expect(described_class::SUPPORTED_LOCALES[:ja]).to eq ['Japanese', '日本語']
  end
end
