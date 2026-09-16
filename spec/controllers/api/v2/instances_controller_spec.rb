# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V2::InstancesController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'returns http success' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'includes the filter_v2 capability' do
      get :show

      expect(JSON.parse(response.body)['fedibird_capabilities']).to include('filter_v2')
    end
  end
end
