# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public status history when anonymous API access is disabled' do
  let(:account) { Fabricate(:account, username: 'alice') }
  let(:status) { Fabricate(:status, account: account, text: 'public note', visibility: :public) }

  before do
    allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
    allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
      with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
    end
  end

  it 'keeps the public page and history available while the REST history requires authentication' do
    ClimateControl.modify DISALLOW_UNAUTHENTICATED_API_ACCESS: 'true' do
      get "/@#{account.username}/#{status.id}"
      expect(response).to have_http_status(200)

      get "/@#{account.username}/#{status.id}/history"
      expect(response).to have_http_status(200)

      get "/api/v1/statuses/#{status.id}/history"
      expect(response).to have_http_status(401)
    end
  end
end
