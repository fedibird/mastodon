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
end
