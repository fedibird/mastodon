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

  it 'removes the moved controls from appearance, other, and safety forms' do
    {
      settings_preferences_appearance_path => %w(emoji_scale enable_wide_emoji auto_play_emoji card_reactions_single_line content_emoji_reaction_size),
      settings_preferences_other_path => %w(enable_reaction compact_reaction hide_reaction_counter disable_reaction_streaming hide_list_of_emoji_reactions_to_posts emoji_picker_disable_personal),
      settings_preferences_safety_path => %w(disable_reactions emoji_reaction_fallback_policy),
    }.each do |path, keys|
      get path
      expect(response).to have_http_status(200)
      keys.each do |key|
        expect(response.body).not_to include("user_setting_#{key}")
      end
    end
  end
end
