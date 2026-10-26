# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ExternalContentSettingsController, type: :controller do
  render_views

  let(:admin) { user_with_role('Owner') }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  around do |example|
    previous_mode = Setting.external_bridge_rss_video_policy
    previous_limit = Setting.external_bridge_rss_video_max_download_mib
    example.run
  ensure
    Setting.external_bridge_rss_video_policy = previous_mode
    Setting.external_bridge_rss_video_max_download_mib = previous_limit
    Rails.cache.clear
  end

  before { stub_webpacker_manifest }

  describe 'authorization' do
    it 'shows the defaults to an admin and saves a hybrid cap' do
      sign_in admin, scope: :user

      get :edit

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('admin.external_content_settings.title'))
      expect(response.body).to include('value="remote"')
      expect(response.body).to include('name="form_admin_external_content_settings[external_bridge_rss_video_max_download_mib]"')
      expect(response.body).to include('method="post"')

      patch :update, params: {
        form_admin_external_content_settings: {
          external_bridge_rss_video_policy: 'hybrid',
          external_bridge_rss_video_max_download_mib: '15',
        },
      }

      expect(response).to redirect_to(edit_admin_external_content_settings_path)
      Rails.cache.clear
      expect(Setting.external_bridge_rss_video_policy).to eq 'hybrid'
      expect(Setting.external_bridge_rss_video_max_download_mib).to eq 15
    end

    it 'rejects a cap outside the video attachment limit' do
      sign_in admin, scope: :user

      patch :update, params: {
        form_admin_external_content_settings: {
          external_bridge_rss_video_policy: 'hybrid',
          external_bridge_rss_video_max_download_mib: '100',
        },
      }

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('admin.external_content_settings.max_download'))
      Rails.cache.clear
      expect(Setting.external_bridge_rss_video_policy).to eq 'remote'
    end

    it 'forbids a moderator' do
      sign_in user_with_role('Moderator'), scope: :user

      get :edit
      expect(response).to have_http_status(:forbidden)

      patch :update, params: {
        form_admin_external_content_settings: {
          external_bridge_rss_video_policy: 'hybrid',
          external_bridge_rss_video_max_download_mib: '10',
        },
      }
      expect(response).to have_http_status(:forbidden)
      Rails.cache.clear
      expect(Setting.external_bridge_rss_video_policy).to eq 'remote'
    end

    it 'forbids an ordinary user and sends a signed-out visitor to sign in' do
      sign_in Fabricate(:user), scope: :user
      get :edit
      expect(response).to have_http_status(:forbidden)

      sign_out :user
      get :edit
      expect(response).to have_http_status(:forbidden)
    end
  end
end
