# frozen_string_literal: true

require 'rails_helper'

describe 'Health endpoint with WebUI domain candidates unset' do
  it 'returns OK without adding configured candidates to the host allow list' do
    get '/health'

    expect(response).to have_http_status(200)
    expect(response.body).to eq('OK')
    expect(Rails.configuration.x.web_ui_domains.additional_hosts).to eq([])
    expect(Rails.configuration.x.web_ui_domains.strict_mode_enabled?).to be(false)
  end
end
