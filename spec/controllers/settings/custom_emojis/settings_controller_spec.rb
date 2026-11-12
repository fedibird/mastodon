# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::CustomEmojis::SettingsController, type: :controller do
  # The preference writer starts its own transactions; transactional fixtures
  # would make legacy key updates raise UserPreferences::OpenTransaction.
  self.use_transactional_tests = false
  render_views

  let(:user) { Fabricate(:user, locale: 'en') }

  after do
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  # The admin layout pulls a webpack pack that this environment has not compiled.
  # The template itself is what the setting copy lives in.
  around do |example|
    layout = described_class._layout
    described_class.layout false
    example.run
  ensure
    described_class.layout layout
  end

  before { sign_in user, scope: :user }

  it 'collects emoji display, reaction, and picker controls on one page' do
    get :show
    expect(response).to have_http_status(200)
    # This controller spec renders without the admin layout; page_title lives
    # in content_for, not response.body. Assert the headings rendered in the form.
    %w(display reactions picker).each do |section|
      expect(response.body).to include(I18n.t("emoji_settings.#{section}", locale: :en))
    end
    %w(
      emoji_scale emoji_size_in_single emoji_size_in_multi emoji_size_in_mix emoji_size_in_other
      enable_wide_emoji auto_play_emoji
      enable_reaction compact_reaction hide_reaction_counter disable_reaction_streaming
      card_reactions_single_line hide_list_of_emoji_reactions_to_posts
      enable_wide_emoji_reaction content_emoji_reaction_size
      disable_auto_focus_to_emoji_search emoji_picker_disable_personal
      emoji_picker_prefer_personal emoji_picker_lazy_load_standard emoji_picker_disable_actions max_frequently_used_emojis
    ).each do |key|
      expect(response.body).to include("user_setting_#{key}")
    end
    expect(response.body).to include(settings_custom_emojis_personal_set_path)
  end

  it 'persists the two range values without changing the preference keys' do
    put :update, params: { user: { setting_emoji_scale: '2.4', setting_content_emoji_reaction_size: '28' } }

    expect(response).to redirect_to(settings_custom_emojis_settings_path)

    get :show
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('#user_setting_emoji_scale')['value']).to eq('2.4')
    expect(page.at_css('output[for="user_setting_emoji_scale"]').text).to eq('2.4×')
    expect(page.at_css('#user_setting_content_emoji_reaction_size')['value']).to eq('28')
    expect(page.at_css('output[for="user_setting_content_emoji_reaction_size"]').text).to eq('28 px')
  end

  it 'uses the revised Japanese emoji preference labels and hints' do
    user.update!(locale: 'ja')
    get :show

    [
      '個人セットを使用しない',
      '標準のMastodonのように、標準ピッカーのみを使用します。動作が軽量になります。反映にはページの再読み込みが必要です。',
      '絵文字ピッカーの構築を呼び出し時まで遅延させる',
      '有効にすると絵文字の使用頻度が低い場合にリソースの節約になりますが、ピッカー起動時の動作が遅くなります。',
      '絵文字ピッカーの動作がおかしい場合は無効化をお試しください。',
      'カードの絵文字リアクションを1行に畳む',
      'リアクションのストリーミング反映を無効にする',
    ].each do |copy|
      expect(response.body).to include(copy)
    end
  end

  it 'persists moved preferences through the existing settings writer' do
    put :update, params: { user: {
      setting_enable_wide_emoji: '1',
      setting_auto_play_emoji: '0',
      setting_enable_reaction: '0',
      setting_hide_reaction_counter: '1',
      setting_card_reactions_single_line: '0',
      setting_emoji_picker_lazy_load_standard: '1',
      setting_emoji_picker_disable_actions: '1',
      setting_max_frequently_used_emojis: '16',
    } }

    expect(response).to redirect_to(settings_custom_emojis_settings_path)
    user.reload
    expect(user.setting_enable_wide_emoji).to be true
    expect(user.setting_auto_play_emoji).to be false
    expect(user.setting_enable_reaction).to be false
    expect(user.setting_hide_reaction_counter).to be true
    expect(user.setting_card_reactions_single_line).to be false
    expect(user.setting_emoji_picker_lazy_load_standard).to be true
    expect(user.setting_emoji_picker_disable_actions).to be true
    expect(user.setting_max_frequently_used_emojis.to_i).to eq 16
  end

  it 'preserves personal picker preference while disabled and restores it when re-enabled' do
    put :update, params: { user: {
      setting_emoji_picker_disable_personal: '1',
      setting_emoji_picker_prefer_personal: '1',
    } }
    expect(response).to redirect_to(settings_custom_emojis_settings_path)
    expect(user.reload.setting_emoji_picker_disable_personal).to be true
    expect(user.setting_emoji_picker_prefer_personal).to be true

    get :show
    expect(response.body).not_to include('user_setting_emoji_picker_prefer_personal')
    expect(response.body).not_to include(settings_custom_emojis_personal_set_path)

    put :update, params: { user: { setting_emoji_picker_disable_personal: '0' } }
    expect(user.reload.setting_emoji_picker_disable_personal).to be false
    expect(user.setting_emoji_picker_prefer_personal).to be true
  end

  it 'does not publish Like fallback or broad action safety controls in the emoji settings form' do
    get :show

    expect(response).to have_http_status(200)
    expect(response.body).not_to include('user_setting_emoji_reaction_fallback_policy')
    expect(response.body).not_to include('user_setting_disable_reactions')
    expect(response.body).not_to include(I18n.t('preferences.emoji_reaction_fallback_policy', locale: :en))
  end

  it 'keeps the picker action-menu setting available when personal sets are disabled' do
    put :update, params: { user: { setting_emoji_picker_disable_personal: '1' } }
    expect(response).to redirect_to(settings_custom_emojis_settings_path)

    get :show

    expect(response.body).to include('user_setting_emoji_picker_disable_actions')
    expect(response.body).not_to include('user_setting_emoji_picker_prefer_personal')
  end
end
