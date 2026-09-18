# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExtendedDescription do
  around do |example|
    Setting.unscoped.where(var: 'site_extended_description').delete_all
    example.run
    Setting.unscoped.where(var: 'site_extended_description').delete_all
  end

  describe '.current' do
    it 'returns no description when the setting is missing' do
      description = described_class.current

      expect(description.text).to be_nil
      expect(description.updated_at).to be_nil
    end

    it 'returns the stored HTML and updated_at' do
      setting = Setting.create!(var: 'site_extended_description', value: '<h2>Hello</h2>')
      description = described_class.current

      expect(description.text).to eq '<h2>Hello</h2>'
      expect(description.updated_at).to eq setting.updated_at
    end

    it 'returns no description when the stored value is blank' do
      Setting.create!(var: 'site_extended_description', value: '')
      description = described_class.current

      expect(description.text).to be_nil
      expect(description.updated_at).to be_nil
    end
  end
end
