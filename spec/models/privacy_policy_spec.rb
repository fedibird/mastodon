# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PrivacyPolicy do
  around do |example|
    Setting.unscoped.where(var: 'site_terms').delete_all
    example.run
  ensure
    Setting.unscoped.where(var: 'site_terms').delete_all
  end

  describe '.current' do
    it 'returns the bundled default policy when the setting is missing' do
      policy = described_class.current

      expect(policy.text).to eq I18n.t('terms.body_html', locale: I18n.default_locale)
      expect(policy.updated_at).to eq described_class::DEFAULT_UPDATED_AT
    end

    it 'returns the stored HTML and updated_at' do
      setting = Setting.create!(var: 'site_terms', value: '<h2>My privacy policy</h2>')
      setting.reload
      policy = described_class.current

      expect(policy.text).to eq '<h2>My privacy policy</h2>'
      expect(policy.updated_at).to eq setting.updated_at
    end

    it 'falls back to the bundled default when the stored value is blank' do
      Setting.create!(var: 'site_terms', value: '')
      policy = described_class.current

      expect(policy.text).to eq I18n.t('terms.body_html', locale: I18n.default_locale)
      expect(policy.updated_at).to eq described_class::DEFAULT_UPDATED_AT
    end
  end
end
