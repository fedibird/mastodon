# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::PrivacyPoliciesController, type: :controller do
  render_views

  around do |example|
    Setting.unscoped.where(var: 'site_terms').delete_all
    example.run
  ensure
    Setting.unscoped.where(var: 'site_terms').delete_all
  end

  describe 'GET #show' do
    it 'returns http success without an OAuth token' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'returns the bundled default policy when no custom terms exist' do
      get :show

      expect(body_as_json).to eq(
        updated_at: PrivacyPolicy::DEFAULT_UPDATED_AT.iso8601,
        content: I18n.t('terms.body_html', locale: I18n.default_locale)
      )
    end

    it 'returns the stored HTML without Markdown conversion' do
      html = '<h2>Custom</h2><p>Hello <strong>world</strong></p>'
      setting = Setting.create!(var: 'site_terms', value: html)

      get :show

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq(
        updated_at: setting.updated_at.iso8601,
        content: html
      )
    end
  end
end
