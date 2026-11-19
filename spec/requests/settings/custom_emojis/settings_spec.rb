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

  it 'does not expose unpublished Like compatibility or safety-wide action controls' do
    get settings_custom_emojis_settings_path

    expect(response).to have_http_status(200)
    expect(response.body).to include('user_setting_emoji_picker_disable_standard')
    expect(response.body).to include('user_setting_emoji_picker_disable_actions')
    expect(response.body).to include('user_setting_emoji_preview_click_action')
    expect(response.body).to include('user_setting_emoji_mute_disable_actions')
    expect(response.body).not_to include('user_setting_emoji_reaction_fallback_policy')
    expect(response.body).not_to include('user_setting_disable_reactions')
  end
  it 'saves preview click behavior and mute safety independently of personal sets' do
    put settings_custom_emojis_settings_path, params: {
      user: {
        setting_emoji_preview_click_action: 'copy',
        setting_emoji_mute_disable_actions: '1',
        setting_emoji_picker_disable_actions: '1',
        setting_emoji_picker_disable_personal: '0',
      },
    }

    expect(response).to have_http_status(:redirect)
    user.reload
    expect(user.setting_emoji_preview_click_action).to eq('copy')
    expect(user.setting_emoji_mute_disable_actions).to eq(true)
    expect(user.setting_emoji_picker_disable_actions).to eq(true)
    expect(user.setting_emoji_picker_disable_personal).to eq(false)
  end

  it 'rejects unknown preview actions before changing any settings' do
    put settings_custom_emojis_settings_path, params: {
      user: {
        setting_emoji_preview_click_action: 'dangerous_unknown_action',
        setting_emoji_mute_disable_actions: '1',
      },
    }

    expect(response).to have_http_status(:unprocessable_entity)
    user.reload
    expect(user.setting_emoji_preview_click_action).to eq('none')
    expect(user.setting_emoji_mute_disable_actions).to eq(false)
  end
  it 'marks the mute manager read-only when the user safety flag is enabled' do
    user.settings['emoji_mute_disable_actions'] = true
    user.save!

    get settings_custom_emojis_mutes_path

    expect(response).to have_http_status(200)
    expect(response.body).to include('data-disable-mute-actions="true"')
  end

end
