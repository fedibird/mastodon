# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PreferencesController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:accounts') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #index' do
    it 'returns reading:autoplay:gifs as false by default' do
      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json[:'reading:autoplay:gifs']).to be false
    end

    it 'falls back posting:default:language to the user locale when the default is invalid' do
      user.update!(locale: 'ja')
      user.settings['default_language'] = 'invalid'

      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json[:'posting:default:language']).to eq 'ja'
    end
  end
end
