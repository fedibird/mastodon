# frozen_string_literal: true

require 'rails_helper'

describe ComposerToolbarPreference do
  def placements(items)
    items.map { |item| item['placement'] }
  end

  describe '.normalize' do
    it 'uses the current footer order and then the current menu order' do
      expect(described_class.normalize(nil).map { |item| item['id'] }).to eq described_class::IDS
      expect(placements(described_class.normalize(nil))).to eq %w(visible visible visible visible menu menu menu)
      expect(described_class.normalize('hello')).to eq described_class.default_items
    end

    it 'drops unknown ids, repairs placements, and appends missing controls' do
      items = described_class.normalize('v1|nope:visible|poll:visible|media:sideways|cw:hidden|cw:menu')

      expect(items.map { |item| item['id'] }).to eq %w(poll media cw posting_account language datetime searchability)
      expect(items.find { |item| item['id'] == 'poll' }['placement']).to eq 'visible'
      expect(items.find { |item| item['id'] == 'media' }['placement']).to eq 'visible'
      expect(items.find { |item| item['id'] == 'cw' }['placement']).to eq 'hidden'
    end

    it 'reads an older json document' do
      raw = { 'v' => 1, 'items' => [{ 'id' => 'language', 'placement' => 'hidden', 'extra' => 'x' }] }.to_json
      items = described_class.normalize(raw)

      expect(items.first).to eq('id' => 'language', 'placement' => 'hidden')
      expect(items.size).to eq 7
    end
  end

  describe '.accept!' do
    it 'rejects values that are not a complete layout' do
      expect { described_class.accept!(nil) }.to raise_error(described_class::Invalid)
      expect { described_class.accept!('hello') }.to raise_error(described_class::Invalid)
      expect { described_class.accept!('v1|media:visible') }.to raise_error(described_class::Invalid)
      expect { described_class.accept!("#{described_class.dump(described_class.default_items)}|nope:hidden") }.to raise_error(described_class::Invalid)
    end

    it 'accepts a reordered canonical layout' do
      raw = described_class.dump(described_class.default_items.reverse)

      expect(described_class.accept!(raw).map { |item| item['id'] }).to eq described_class::IDS.reverse
    end
  end

  it 'is not part of the Mastodon preferences API' do
    expect(UserPreferences::Reader::KEYS).not_to include(described_class::VAR)
    expect(UserPreferences::WriteContract::KEYS).not_to include(described_class::VAR)
  end
end
