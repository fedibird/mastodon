# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::SearchText do
  def account(display_name: '', username: 'group', domain: nil, note: '')
    instance_double(Account, display_name: display_name, username: username, domain: domain, note: note)
  end

  it 'folds width and accents and keeps % and _ literal' do
    expect(described_class.fold("\uFF23\uFF41\uFF46\u00E9")).to eq('cafe')
    expect(described_class.fold('100%_done')).to include('%_')
  end

  it 'uses one window up to 20 characters and overlaps the tail after that' do
    expect(described_class.windows('a' * 20)).to eq(['a' * 20])
    longer = "#{'a' * 20}XYZ"
    windows = described_class.windows(longer)
    expect(windows).to all(have_attributes(length: 20))
    expect(windows.first).to eq('a' * 20)
    expect(windows.last).to end_with('XYZ')
    expect(described_class.windows('a' * 100).size).to be <= 12
  end

  it 'requires the whole query inside one field' do
    token = "#{'0123456789abcdefghij'}XXXXX"
    split = account(display_name: token[0, 20], note: token[5, 20])
    whole = account(note: "prefix #{token} suffix")

    expect(described_class.contiguous?(split, token)).to be false
    expect(described_class.contiguous?(whole, token)).to be true
    expect(described_class.contiguous?(account(display_name: '100%_done'), '100%_done')).to be true
    expect(described_class.contiguous?(account(display_name: "\uFF23\uFF41\uFF46\u00E9"), 'cafe')).to be true
  end
end
