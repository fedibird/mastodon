# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ActionReviewSettingsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:admin) { Fabricate(:user, admin: true) }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def option_values(body, field)
    Nokogiri::HTML(body).css("select[name='form_action_review_settings[#{field}]'] option").map { |node| node['value'] }
  end

  def selected_value(body, field)
    Nokogiri::HTML(body).at_css("select[name='form_action_review_settings[#{field}]'] option[selected]")&.[]('value')
  end

  def store_policies(value)
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(value: value)
    Rails.cache.clear
  end

  around do |example|
    example.run
  ensure
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  before do
    stub_webpacker_manifest
  end

  describe 'authorization' do
    it 'allows an admin to view and update settings' do
      sign_in admin, scope: :user

      get :edit
      expect(response).to have_http_status(200)

      patch :update, params: { form_action_review_settings: { follow_import: 'high' } }
      expect(response).to redirect_to(edit_admin_action_review_settings_path)
    end

    it 'forbids a moderator from changing site policy' do
      sign_in Fabricate(:user, moderator: true), scope: :user

      get :edit
      expect(response).to have_http_status(:forbidden)

      patch :update, params: { form_action_review_settings: { follow_import: 'high' } }
      expect(response).to have_http_status(:forbidden)
      expect(Setting['action_review_policies']['follow_import']).to eq 'off'
    end

    it 'forbids an ordinary user' do
      sign_in Fabricate(:user), scope: :user

      get :edit
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET #edit' do
    before { sign_in admin, scope: :user }

    it 'loads default off modes and supported choices' do
      get :edit

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('admin.action_review_settings.title'))
      expect(option_values(response.body, 'follow_import')).to eq %w(off high medium low always)
      expect(option_values(response.body, 'account_migration')).to eq %w(off always)
      expect(option_values(response.body, 'invite_creation')).to eq %w(off always)
      expect(option_values(response.body, 'status_import')).to eq %w(off always)
      expect(response.body).to include(I18n.t('admin.action_review_settings.operations.status_import'))
      expect(response.body).to include(I18n.t('admin.action_review_settings.hints.follow_import'))
      expect(response.body).to include('always sends every Follow Import')
      expect(response.body).to include('shadow review signal')
      expect(response.body).to include('do not hold imports yet')
      expect(response.body).to include('code stays unusable until then')
      expect(I18n.t('admin.action_review_settings.preface')).to include('shadow classifier')
      expect(I18n.t('admin.action_review_settings.preface')).to include('do not hold imports yet')
      expect(I18n.t('admin.action_review_settings.preface')).to include('normal portability')
      expect(I18n.t('admin.action_review_settings.preface')).to include('Status import is not connected')
      expect(I18n.t('admin.action_review_settings.hints.account_migration')).to include('normal Fediverse portability')
      expect(I18n.t('admin.action_review_settings.hints.account_migration')).to include('staff approval before follower transfer')
      expect(I18n.t('admin.action_review_settings.hints.status_import')).to include('does not enable status import')
      expect(I18n.t('admin.action_review_settings.hints.follow_import', locale: :ja)).to include('シャドー')
      expect(I18n.t('admin.action_review_settings.hints.invite_creation', locale: :ja)).to include('承認するまで')
    end

    it 'selects effective always when stored detectorless or malformed values would not match the collection' do
      store_policies(
        'follow_import' => 'dangerous',
        'account_migration' => 'off',
        'invite_creation' => 'medium',
        'status_import' => 'off'
      )

      get :edit

      expect(response).to have_http_status(200)
      expect(selected_value(response.body, 'follow_import')).to eq 'always'
      expect(selected_value(response.body, 'invite_creation')).to eq 'always'
    end

    it 'renders always when the stored setting blob is not a hash' do
      store_policies('off')

      get :edit

      expect(response).to have_http_status(200)
      expect(selected_value(response.body, 'follow_import')).to eq 'always'
      expect(selected_value(response.body, 'invite_creation')).to eq 'always'
    end
  end

  describe 'PATCH #update' do
    before { sign_in admin, scope: :user }

    it 'persists valid settings without creating review requests' do
      expect do
        patch :update, params: {
          form_action_review_settings: {
            follow_import: 'low',
            account_migration: 'always',
            invite_creation: 'off',
            status_import: 'off',
          },
        }
      end.not_to change(ActionReviewRequest, :count)

      expect(response).to redirect_to(edit_admin_action_review_settings_path)
      expect(Setting['action_review_policies']).to include(
        'follow_import' => 'low',
        'account_migration' => 'always'
      )
      expect(ActionReview::PolicySettings.mode_for('follow_import')).to eq 'low'
    end

    it 're-renders when an unsupported detectorless mode is submitted' do
      patch :update, params: {
        form_action_review_settings: {
          follow_import: 'off',
          account_migration: 'off',
          invite_creation: 'medium',
          status_import: 'off',
        },
      }

      expect(response).to have_http_status(200)
      expect(assigns(:form).errors[:invite_creation]).to be_present
      expect(Setting['action_review_policies']['invite_creation']).to eq 'off'
    end

    it 'does not persist an unknown operation key' do
      patch :update, params: {
        form_action_review_settings: {
          follow_import: 'high',
          widget_import: 'always',
        },
      }

      expect(response).to redirect_to(edit_admin_action_review_settings_path)
      expect(Setting['action_review_policies'].keys).not_to include('widget_import')
      expect(Setting['action_review_policies']['follow_import']).to eq 'high'
    end
  end
end
