# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::ExtendedDescriptionsController, type: :controller do
  render_views

  around do |example|
    Setting.unscoped.where(var: 'site_extended_description').delete_all
    example.run
    Setting.unscoped.where(var: 'site_extended_description').delete_all
  end

  describe 'GET #show' do
    it 'returns http success without an OAuth token' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'returns empty content when no description is configured' do
      get :show

      expect(body_as_json).to eq(updated_at: nil, content: '')
    end

    it 'returns the stored HTML without Markdown conversion' do
      html = '<h2>About</h2><p>Hello <strong>world</strong></p>'
      setting = Setting.create!(var: 'site_extended_description', value: html)

      get :show

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq(
        updated_at: setting.updated_at.iso8601,
        content: html
      )
    end
  end
end
