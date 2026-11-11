# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Settings custom emoji preferences page', type: :request do
  let(:user) { Fabricate(:user, confirmed_at: Time.now.utc, locale: 'ja') }

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  it 'shows the new navigation entry and settings form' do
    get settings_custom_emojis_settings_path

    expect(response).to have_http_status(200)
    expect(response.body).to include(I18n.t('settings.emoji_settings', locale: :ja))
    expect(response.body).to include('id="edit_emoji_settings"')
    expect(response.body).to include(settings_custom_emojis_personal_set_path)
    expect(response.body).to include(settings_custom_emojis_mutes_path)
  end
end
