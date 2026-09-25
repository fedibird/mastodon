# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Content-Security-Policy' do
  let(:api_policy) { "default-src 'none'; frame-ancestors 'none'; form-action 'none'" }

  describe 'API controllers' do
    before do
      stub_const('Api::V1::CspTestsController', Class.new(Api::BaseController) do
        def show
          render json: {}
        end
      end)

      Rails.application.routes.draw do
        get '/api/v1/csp_test' => 'api/v1/csp_tests#show'
      end
    end

    after { Rails.application.reload_routes! }

    it 'sends the minimal API policy' do
      get '/api/v1/csp_test'

      expect(response).to have_http_status(200)
      expect(response.headers['Content-Security-Policy']).to eq(api_policy)
    end
  end

  describe 'GET /api/v1/accounts/lookup' do
    let!(:account) { Fabricate(:account, username: 'alice') }

    it 'uses the minimal API policy on a real endpoint' do
      get '/api/v1/accounts/lookup', params: { acct: 'alice' }

      policy = response.headers['Content-Security-Policy'].to_s

      expect(response).to have_http_status(200)
      expect(policy).to eq(api_policy)
      expect(policy).not_to include('img-src', 'script-src', 'connect-src')
    end
  end

  describe 'non-API controllers' do
    before do
      stub_const('CspHtmlTestsController', Class.new(ApplicationController) do
        def show
          head 200
        end
      end)

      Rails.application.routes.draw do
        get '/csp_html_test' => 'csp_html_tests#show'
      end
    end

    after { Rails.application.reload_routes! }

    it 'keeps the application UI policy' do
      get '/csp_html_test'

      policy = response.headers['Content-Security-Policy'].to_s

      expect(response).to have_http_status(200)
      expect(policy).to include('img-src', 'script-src', 'connect-src')
      expect(policy).not_to eq(api_policy)
    end
  end
end
