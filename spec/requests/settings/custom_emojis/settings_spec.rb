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

  {
    appearance: {
      path_helper: :settings_preferences_appearance_path,
      heading: 'appearance.themes',
      keys: %w(emoji_scale enable_wide_emoji auto_play_emoji card_reactions_single_line content_emoji_reaction_size),
    },
    other: {
      path_helper: :settings_preferences_other_path,
      heading: 'preferences.relationship_disclosure',
      keys: %w(enable_reaction compact_reaction hide_reaction_counter disable_reaction_streaming hide_list_of_emoji_reactions_to_posts emoji_picker_disable_personal),
    },
    safety: {
      path_helper: :settings_preferences_safety_path,
      heading: 'preferences.disable_actions',
      keys: %w(disable_reactions emoji_reaction_fallback_policy),
    },
  }.each do |page, config|
    it "does not display moved emoji fields on the #{page} settings page" do
      path = public_send(config[:path_helper])
      get path

      # Some request environments issue a redirect; the destination must still
      # be the intended authenticated settings form, not a login/error page.
      follow_redirect! if response.redirect?
      expect(response).to have_http_status(200), "#{path} -> #{response.location.inspect}"
      expect(response.body).to include(I18n.t(config[:heading], locale: :ja))

      config[:keys].each do |key|
        expect(response.body).not_to include("user_setting_#{key}")
      end
    end
  end
end
