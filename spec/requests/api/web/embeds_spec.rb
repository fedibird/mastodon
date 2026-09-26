# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Web Embeds API' do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def get_embed(status, authenticated: false)
    request_headers = authenticated ? headers : {}
    get "/api/web/embeds/#{status.id}", headers: request_headers, as: :json
  end

  describe 'GET /api/web/embeds/:id' do
    context 'when the viewer is anonymous' do
      it 'returns oEmbed HTML for a local public status' do
        status = Fabricate(:status, visibility: :public)

        get_embed(status)

        expect(response).to have_http_status(200)
        expect(body_as_json[:html]).to include('mastodon-embed')
        expect(body_as_json[:author_name]).to eq(status.account.display_name.presence || status.account.username)
      end

      it 'returns oEmbed HTML for a local unlisted status' do
        status = Fabricate(:status, visibility: :unlisted)

        get_embed(status)

        expect(response).to have_http_status(200)
        expect(body_as_json[:html]).to include('mastodon-embed')
      end

      it 'returns 404 for a local private status' do
        status = Fabricate(:status, visibility: :private)

        get_embed(status)

        expect(response).to have_http_status(404)
      end

      it 'returns 404 for a remote public status' do
        status = Fabricate(:status, visibility: :public, local: false, uri: 'https://example.com/users/bob/statuses/1', url: 'https://example.com/@bob/1', account: Fabricate(:account, domain: 'example.com', username: 'bob'))

        get_embed(status)

        expect(response).to have_http_status(404)
      end

      it 'returns 404 when the status does not exist' do
        get '/api/web/embeds/0', as: :json

        expect(response).to have_http_status(404)
      end
    end

    context 'when the viewer is authenticated' do
      it 'returns oEmbed HTML for a local public status' do
        status = Fabricate(:status, visibility: :public)

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(200)
        expect(body_as_json[:html]).to include('mastodon-embed')
      end

      it 'returns 404 for a local private status even when following the author' do
        author = Fabricate(:account)
        user.account.follow!(author)
        status = Fabricate(:status, account: author, visibility: :private)

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(404)
      end

      it 'returns 404 for a blocked local public status' do
        status = Fabricate(:status, visibility: :public)
        status.account.block!(user.account)

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(404)
      end

      it 'fetches remote oEmbed from the status canonical URL' do
        status = Fabricate(:status, visibility: :public, local: false, uri: 'https://example.com/users/bob/statuses/1', url: 'https://example.com/@bob/1', account: Fabricate(:account, domain: 'example.com', username: 'bob'))
        service = instance_double(FetchOEmbedService)
        allow(FetchOEmbedService).to receive(:new).and_return(service)
        expect(service).to receive(:call).with('https://example.com/@bob/1').and_return(html: '<iframe src="https://example.com/embed" width="400" height="400"></iframe>')

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(200)
        expect(body_as_json[:html]).to include('iframe')
        expect(body_as_json[:html]).to include('sandbox=')
      end

      it 'returns 404 when remote oEmbed cannot be fetched' do
        status = Fabricate(:status, visibility: :public, local: false, uri: 'https://example.com/users/bob/statuses/1', url: 'https://example.com/@bob/1', account: Fabricate(:account, domain: 'example.com', username: 'bob'))
        service = instance_double(FetchOEmbedService, call: nil)
        allow(FetchOEmbedService).to receive(:new).and_return(service)

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(404)
      end

      it 'returns 404 when remote oEmbed HTML cannot be sanitized' do
        status = Fabricate(:status, visibility: :public, local: false, uri: 'https://example.com/users/bob/statuses/1', url: 'https://example.com/@bob/1', account: Fabricate(:account, domain: 'example.com', username: 'bob'))
        service = instance_double(FetchOEmbedService, call: { html: '<iframe></iframe>' })
        allow(FetchOEmbedService).to receive(:new).and_return(service)
        allow(Formatter.instance).to receive(:sanitize).and_raise(ArgumentError)

        get_embed(status, authenticated: true)

        expect(response).to have_http_status(404)
      end
    end
  end
end
