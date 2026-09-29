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

      expect(response.body).to include(I18n.t('external_credentials.appearance_link_html', path: settings_external_credentials_path))
      expect(response.body).to include(settings_external_credentials_path)
    end

    it 'links the Japanese appearance hint to 外部サービス' do
      user = Fabricate(:user, locale: 'ja')
      sign_in user, scope: :user

      get :show

      expect(response.body).to include('個人のDeepL APIキーは')
      expect(response.body).to include('外部サービス')
      expect(response.body).to include(settings_external_credentials_path)
    end
  end
end
