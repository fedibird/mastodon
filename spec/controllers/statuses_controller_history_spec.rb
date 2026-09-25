# frozen_string_literal: true

require 'rails_helper'

describe StatusesController do
  render_views

  before do
    allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
    allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
      with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
    end
  end

  describe 'GET #history' do
    let(:account) { Fabricate(:account, username: 'alice') }
    let(:status) { Fabricate(:status, account: account, text: 'original history', visibility: :public) }

    def history_json
      body_as_json
    end

    it 'returns the public history to an anonymous viewer and does not store the location' do
      status.snapshot!(at_time: status.created_at, rate_limit: false)
      status.update!(text: 'edited history', edited_at: Time.now.utc)
      status.snapshot!(at_time: status.edited_at, rate_limit: false)

      get :show, params: { account_username: account.username, id: status.id }
      expect(response).to have_http_status(200)
      expect(response.body).to include('data-component="StatusHistory"')
      expect(response.body).to include('class="dt-updated"')

      get :history, params: { account_username: account.username, id: status.id }

      expect(response).to have_http_status(200)
      expect(session['user_return_to'].to_s).not_to include('/history')
      expect(history_json.map { |item| item[:content] }.join).to include('original history')
      expect(history_json.map { |item| item[:content] }.join).to include('edited history')
      expect(history_json.first).to include(:spoiler_text, :sensitive, :created_at, :account, :media_attachments)
    end

    it 'returns an unlisted history to an anonymous viewer' do
      unlisted = Fabricate(:status, account: account, visibility: :unlisted, text: 'quiet')

      get :history, params: { account_username: account.username, id: unlisted.id }

      expect(response).to have_http_status(200)
      expect(history_json.first[:content]).to include('quiet')
    end

    it 'hides a private history from an anonymous viewer' do
      hidden = Fabricate(:status, account: account, visibility: :private, text: 'secret')

      get :show, params: { account_username: account.username, id: hidden.id }
      expect(response).to have_http_status(404)

      get :history, params: { account_username: account.username, id: hidden.id }
      expect(response).to have_http_status(404)
    end

    it 'shows a private history to an authorized follower' do
      hidden = Fabricate(:status, account: account, visibility: :private, text: 'secret')
      user = Fabricate(:user)
      user.account.follow!(account)
      sign_in(user)

      get :history, params: { account_username: account.username, id: hidden.id }

      expect(response).to have_http_status(200)
      expect(history_json.first[:content]).to include('secret')
    end

    it 'hides direct, limited, and personal history from anonymous viewers and other users' do
      owner = Fabricate(:user)
      stranger = Fabricate(:user)
      hidden_statuses = [
        Fabricate(:status, account: owner.account, visibility: :direct, text: 'direct note'),
        Fabricate(:status, account: owner.account, visibility: :limited, text: 'circle note'),
        Fabricate(:status, account: owner.account, visibility: :personal, text: 'personal note'),
      ]

      hidden_statuses.each do |hidden|
        get :history, params: { account_username: owner.account.username, id: hidden.id }
        expect(response).to have_http_status(404)
      end

      sign_in(stranger)
      controller.remove_instance_variable(:@current_account) if controller.instance_variable_defined?(:@current_account)

      hidden_statuses.each do |hidden|
        get :history, params: { account_username: owner.account.username, id: hidden.id }
        expect(response).to have_http_status(404)
      end
    end

    it 'shows direct, limited, and personal history to the author' do
      owner = Fabricate(:user)
      hidden_statuses = [
        Fabricate(:status, account: owner.account, visibility: :direct, text: 'direct note'),
        Fabricate(:status, account: owner.account, visibility: :limited, text: 'circle note'),
        Fabricate(:status, account: owner.account, visibility: :personal, text: 'personal note'),
      ]

      sign_in(owner)

      hidden_statuses.each do |hidden|
        get :history, params: { account_username: owner.account.username, id: hidden.id }
        expect(response).to have_http_status(200)
        expect(history_json.first[:content]).to include(hidden.text)
      end
    end

    it 'serializes a local media attachment from the historical snapshot' do
      media = Fabricate(:media_attachment, account: account, status: status, description: 'before edit', type: :image)
      status.snapshot!(at_time: status.created_at, rate_limit: false)
      media.update!(description: 'after edit')

      get :history, params: { account_username: account.username, id: status.id }

      expect(response).to have_http_status(200)
      media_json = history_json.first[:media_attachments].first
      expect(media_json[:id]).to eq media.id.to_s
      expect(media_json[:text_url]).to end_with("/media/#{media.to_param}")
      expect(media_json[:description]).to eq 'before edit'
    end

    it 'returns a synthetic snapshot when the status has not been edited' do
      get :history, params: { account_username: account.username, id: status.id }

      expect(response).to have_http_status(200)
      expect(history_json.size).to eq 1
      expect(history_json.first[:content]).to include('original history')
    end
  end
end
