# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'form-action Content-Security-Policy' do
  before { stub_webpacker_manifest }

  def directives
    response.headers['Content-Security-Policy'].to_s.split(';').map(&:strip)
  end

  describe 'a normal HTML response' do
    before do
      stub_const('CspFormActionTestsController', Class.new(ApplicationController) do
        def show
          render plain: 'ok', layout: false
        end
      end)

      Rails.application.routes.draw do
        get '/csp_form_action_test' => 'csp_form_action_tests#show'
      end
    end

    after { Rails.application.reload_routes! }

    it 'limits form submissions to the same origin' do
      get '/csp_form_action_test'

      expect(response).to have_http_status(200)
      expect(directives).to include("form-action 'self'")
      expect(directives).to include("default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'")
    end
  end

  describe 'GET /oauth/authorize' do
    let(:user) { Fabricate(:user) }
    let(:oauth_app) { Doorkeeper::Application.create!(name: 'test', redirect_uri: 'http://localhost/', scopes: 'read') }

    before { sign_in user, scope: :user }

    it 'disables only the form-action directive' do
      get '/oauth/authorize', params: { client_id: oauth_app.uid, response_type: 'code', redirect_uri: 'http://localhost/', scope: 'read' }

      expect(response).to have_http_status(200)
      expect(directives.none? { |directive| directive.start_with?('form-action ') }).to be true
      expect(directives).to include("default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'")
      expect(response.body).to include('Authorize', 'Deny')
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
