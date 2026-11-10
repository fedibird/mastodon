# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Settings custom emoji mutes page', type: :request do
  let(:user) { Fabricate(:user, confirmed_at: Time.now.utc) }

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  it 'renders the mute settings mount point for the signed-in owner' do
    get settings_custom_emojis_mutes_path

    expect(response).to have_http_status(200)
    expect(response.body).to include('id="emoji-mutes"')
    expect(response.body).to include('emoji_mutes')
  end

  it 'does not expose mute rules in the initial HTML' do
    get settings_custom_emojis_mutes_path

    expect(response.body).not_to include('emoji_mutes":')
    expect(response.body).not_to include('replace_in_text')
  end
end
