# frozen_string_literal: true

require 'rails_helper'

describe 'WebAuthn configuration' do
  let(:origin) { "#{Rails.configuration.x.use_https ? 'https' : 'http' }://#{Rails.configuration.x.web_domain}" }

  it 'allows only the existing WEB_DOMAIN origin' do
    expect(WebAuthn.configuration.allowed_origins).to eq([origin])
  end

  it 'keeps the relying party name, timeout, and implicit RP ID' do
    expect(WebAuthn.configuration.rp_name).to eq('Mastodon')
    expect(WebAuthn.configuration.credential_options_timeout).to eq(120_000)
    expect(WebAuthn.configuration.rp_id).to be_nil
  end
end
