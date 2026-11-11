# frozen_string_literal: true

require 'rails_helper'

describe Settings::Preferences::AppearanceController do
  render_views

  before do
    allow_any_instance_of(Webpacker::Manifest).to receive(:lookup!) do |*_args, **kwargs|
      kwargs[:with_integrity] ? ['/packs-test/dummy.js', nil] : '/packs-test/dummy.js'
    end
  end

  describe 'GET #show' do
    it 'links personal DeepL setup to External services' do
      user = Fabricate(:user, locale: 'en')
      sign_in user, scope: :user

      get :show

      expect(response.body).to include(I18n.t('external_credentials.appearance_link_html', path: settings_external_services_deepl_path))
      expect(response.body).to include(settings_external_services_deepl_path)
    end

    it 'links the Japanese appearance hint to 外部サービス' do
      user = Fabricate(:user, locale: 'ja')
      sign_in user, scope: :user

      get :show

      expect(response.body).to include('個人のDeepL APIキーは')
      expect(response.body).to include('外部サービス')
      expect(response.body).to include(settings_external_services_deepl_path)
    end

    it 'shows separate image crop controls in the appearance form' do
      user = Fabricate(:user, locale: 'ja')
      sign_in user, scope: :user

      get :show

      expect(response.body).to include('user_setting_crop_images')
      expect(response.body).to include('user_setting_crop_card_images')
      expect(response.body).to include(I18n.t('simple_form.labels.defaults.setting_crop_images', locale: :ja))
      expect(response.body).to include(I18n.t('simple_form.labels.defaults.setting_crop_card_images', locale: :ja))
    end

    it 'groups standard posts, cards, and media separately from link previews' do
      user = Fabricate(:user, locale: 'ja')
      sign_in user, scope: :user

      get :show

      body = response.body
      expect(body).to include(I18n.t('appearance.standard_status_display', locale: :ja))
      expect(body).to include(I18n.t('appearance.card_display', locale: :ja))
      expect(body).to include(I18n.t('appearance.media_display', locale: :ja))
      expect(body).to include(I18n.t('appearance.preview_card', locale: :ja))
      expect(body.index(I18n.t('appearance.card_display', locale: :ja))).to be < body.index(I18n.t('appearance.preview_card', locale: :ja))
      expect(body).not_to include('user_setting_card_reactions_single_line')
      expect(body).to include('user_setting_card_collapse_long_text')
      expect(body).not_to include('user_setting_card_timeline_scroll_zone')
      expect(body).to include('user_setting_media_display_shape')
      expect(body).to include('user_setting_media_display_size')
      expect(body).not_to include('user_setting_emoji_scale')
      expect(body).not_to include('user_setting_content_emoji_reaction_size')
      expect(body).not_to include('user_setting_auto_play_emoji')
      expect(body).not_to include(I18n.t('simple_form.labels.defaults.setting_card_reactions_single_line', locale: :ja))
      expect(body).to include(I18n.t('simple_form.labels.defaults.setting_card_collapse_long_text', locale: :ja))
    end
  end

  describe 'PUT #update (image crop preferences)' do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }

    it 'persists regular and card crop settings independently in either combination' do
      put :update, params: { user: { setting_crop_images: '0', setting_crop_card_images: '1' } }
      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(user.reload.setting_crop_images).to be false
      expect(user.setting_crop_card_images).to be true

      put :update, params: { user: { setting_crop_images: '1', setting_crop_card_images: '0' } }
      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(user.reload.setting_crop_images).to be true
      expect(user.setting_crop_card_images).to be false
    end
  end

  describe 'PUT #update (card and media display defaults)' do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }

    it 'uses the historical defaults before a user saves anything' do
      expect(user.setting_card_reactions_single_line).to be true
      expect(user.setting_card_collapse_long_text).to be true
      expect(user.setting_media_display_shape).to eq 'square'
      expect(user.setting_media_display_size).to eq 'small'
    end

    it 'ignores submissions of the retired scroll-zone setting' do
      put :update, params: {
        user: { setting_card_timeline_scroll_zone: '0' },
      }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'card_timeline_scroll_zone').exists?).to be false
    end

    it 'persists the two card flags and safe media defaults' do
      put :update, params: {
        user: {
          setting_card_reactions_single_line: '0',
          setting_card_collapse_long_text: '0',
          setting_media_display_shape: 'original',
          setting_media_display_size: 'large',
        },
      }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      user.reload
      expect(user.setting_card_reactions_single_line).to be false
      expect(user.setting_card_collapse_long_text).to be false
      expect(user.setting_media_display_shape).to eq 'original'
      expect(user.setting_media_display_size).to eq 'large'

      put :update, params: {
        user: {
          setting_media_display_shape: 'circle',
          setting_media_display_size: 'huge',
        },
      }

      user.reload
      expect(user.setting_media_display_shape).to eq 'square'
      expect(user.setting_media_display_size).to eq 'small'
    end
  end
end
