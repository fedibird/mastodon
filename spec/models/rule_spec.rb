# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rule, type: :model do
  describe 'hint' do
    it 'defaults to an empty string when omitted' do
      rule = described_class.create!(text: 'Be kind')

      expect(rule.hint).to eq ''
      expect(rule.reload.hint).to eq ''
    end

    it 'persists a provided hint' do
      rule = described_class.create!(text: 'No spam', hint: 'No commercial posts')

      expect(rule.reload.hint).to eq 'No commercial posts'
    end

    it 'keeps hint when text and priority change' do
      rule = described_class.create!(text: 'Be kind', hint: 'Detail', priority: 1)

      rule.update!(text: 'Be kinder', priority: 2)

      expect(rule.reload.text).to eq 'Be kinder'
      expect(rule.priority).to eq 2
      expect(rule.hint).to eq 'Detail'
    end
  end

  describe 'validations' do
    it 'requires text within TEXT_SIZE_LIMIT' do
      expect(described_class.new(text: '')).to_not be_valid
      expect(described_class.new(text: 'a' * described_class::TEXT_SIZE_LIMIT)).to be_valid
      expect(described_class.new(text: 'a' * (described_class::TEXT_SIZE_LIMIT + 1))).to_not be_valid
    end
  end

  describe '.ordered' do
    it 'returns kept rules by priority, then id' do
      lower_id = described_class.create!(text: 'Lower id', priority: 5)
      higher_id = described_class.create!(text: 'Higher id', priority: 5)
      leading = described_class.create!(text: 'Leading', priority: 1)
      described_class.create!(text: 'Gone', priority: 0, deleted_at: Time.current)

      expect(described_class.ordered).to eq [leading, lower_id, higher_id]
    end
  end
end
