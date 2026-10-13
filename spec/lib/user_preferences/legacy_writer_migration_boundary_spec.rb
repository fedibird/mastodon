# frozen_string_literal: true

require 'rails_helper'

# Current-behavior characterization for the P2-6 migration.
# Production saves still go through UserSettingsDecorator and ScopedSettings.
# Examples that store a Hash or Array, or that write the legacy cache on a
# same-value resubmit, are the behavior a later PR is expected to change.
RSpec.describe 'P2-6 legacy writer migration boundary' do
  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def contract_errors(updates)
    UserPreferences::WriteContract.new.validate!(updates: updates, resets: [])
    []
  rescue UserPreferences::InvalidInput => e
    e.errors
  end

  def expect_public_rejection(key, value, code)
    expect(contract_errors(key => value)).to include('key' => key, 'code' => code)
  end

  describe Settings::Preferences::AppearanceController, type: :controller do
    let(:user) { Fabricate(:user) }

    before { sign_in user, scope: :user }

    it 'stores font sizes as strings and leaves the public contract strict' do
      put :update, params: { user: { setting_content_font_size: '18', setting_info_font_size: '16' } }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      content = stored(user, 'content_font_size')
      info = stored(user, 'info_font_size')
      expect(content.value).to eq '18'
      expect(content.value).to be_a(String)
      expect(info.value).to eq '16'
      expect(info.value).to be_a(String)
      expect(stored(user, 'preferred_posting_language')).to be_nil
      expect_public_rejection('content_font_size', '18', 'invalid_type')
      expect_public_rejection('info_font_size', '16', 'invalid_type')
    end

    it 'casts boolean strings 0 and 1 before saving' do
      put :update, params: { user: { setting_default_sensitive: '0', setting_reduce_motion: '1' } }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(stored(user, 'default_sensitive').value).to be false
      expect(stored(user, 'reduce_motion').value).to be true
      expect_public_rejection('default_sensitive', '0', 'invalid_type')
      expect_public_rejection('reduce_motion', '1', 'invalid_type')
    end

    it 'stores a nil row when a boolean input is an empty string' do
      user.settings['default_sensitive'] = true
      user.settings['reduce_motion'] = true

      put :update, params: { user: { setting_default_sensitive: '', setting_reduce_motion: '' } }

      sensitive = stored(user, 'default_sensitive')
      motion = stored(user, 'reduce_motion')
      expect(sensitive).to be_present
      expect(sensitive.value).to be_nil
      expect(motion).to be_present
      expect(motion.value).to be_nil
      expect(User.find(user.id).setting_default_sensitive).to be_nil
      expect(User.find(user.id).setting_reduce_motion).to be_nil
      expect_public_rejection('default_sensitive', nil, 'null_value')
      expect_public_rejection('reduce_motion', nil, 'null_value')
    end

    it 'normalizes an unknown translation bar with the policy stored before this update' do
      user.settings['new_features_policy'] = 'default'

      put :update, params: {
        user: {
          setting_show_translation_bar: 'nope',
          setting_new_features_policy: 'conservative',
        },
      }

      expect(stored(user, 'show_translation_bar').value).to eq 'target'
      expect(stored(user, 'new_features_policy').value).to eq 'conservative'
      expect_public_rejection('show_translation_bar', 'nope', 'invalid_value')
    end

    it 'normalizes an unknown translation mode to translated' do
      put :update, params: { user: { setting_translation_preferred_mode: 'original' } }

      expect(stored(user, 'translation_preferred_mode').value).to eq 'translated'
      expect(User.find(user.id).setting_translation_preferred_mode).to eq 'translated'
      expect_public_rejection('translation_preferred_mode', 'original', 'invalid_value')
    end

    it 'does not distribute a profile update for appearance keys alone' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)

      put :update, params: {
        user: {
          setting_content_font_size: '18',
          setting_reduce_motion: '1',
          setting_show_translation_bar: 'always',
          setting_translation_preferred_mode: 'bilingual',
        },
      }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(stored(user, 'content_font_size').value).to eq '18'
    end
  end

  describe Settings::Preferences::OtherController, type: :controller do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }

    it 'skips nil inputs and still saves a present sibling' do
      user.settings['default_privacy'] = 'unlisted'
      user.settings['default_sensitive'] = true
      privacy = stored(user, 'default_privacy')
      sensitive = stored(user, 'default_sensitive')
      privacy.update_columns(updated_at: 3.hours.ago)
      sensitive.update_columns(updated_at: 3.hours.ago)
      privacy_stamp = privacy.reload.updated_at
      sensitive_stamp = sensitive.reload.updated_at
      privacy_key = Setting.cache_key('default_privacy', user)
      sensitive_key = Setting.cache_key('default_sensitive', user)
      writes = []
      allow(Rails.cache).to receive(:write).and_wrap_original do |method, cache_key, value, *rest|
        writes << [cache_key, value]
        method.call(cache_key, value, *rest)
      end

      # JSON null stays nil. A form-encoded nil becomes "" and is covered below.
      put :update, params: {
        user: {
          setting_default_privacy: nil,
          setting_default_sensitive: nil,
          setting_default_language: 'de',
        },
      }, as: :json

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(privacy.reload.value).to eq 'unlisted'
      expect(privacy.updated_at).to eq privacy_stamp
      expect(sensitive.reload.value).to be true
      expect(sensitive.updated_at).to eq sensitive_stamp
      expect(stored(user, 'default_language').value).to eq 'de'
      expect(writes.map(&:first)).not_to include(privacy_key, sensitive_key)
      expect_public_rejection('default_privacy', nil, 'null_value')
    end

    it 'stores an empty string when form encoding turns a nil privacy into a blank value' do
      user.settings['default_privacy'] = 'unlisted'

      put :update, params: { user: { setting_default_privacy: nil } }

      expect(stored(user, 'default_privacy').value).to eq ''
      expect(User.find(user.id).setting_default_privacy).to eq ''
    end

    it 'stores privacy direct and an empty privacy string' do
      put :update, params: { user: { setting_default_privacy: 'direct' } }

      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(User.find(user.id).setting_default_privacy).to eq 'direct'
      expect_public_rejection('default_privacy', 'direct', 'invalid_value')

      put :update, params: { user: { setting_default_privacy: '' } }

      expect(stored(user, 'default_privacy').value).to eq ''
      expect(User.find(user.id).setting_default_privacy).to eq ''
      expect_public_rejection('default_privacy', '', 'invalid_value')
    end

    it 'stores a regional language string without writing the derived posting language' do
      put :update, params: { user: { setting_default_language: 'ja-JP' } }

      reloaded = User.find(user.id)
      expect(stored(user, 'default_language').value).to eq 'ja-JP'
      expect(reloaded.setting_default_language).to eq 'ja-JP'
      expect(reloaded.preferred_posting_language).to eq 'ja'
      expect(stored(user, 'preferred_posting_language')).to be_nil
      expect_public_rejection('default_language', 'ja-JP', 'invalid_value')
      expect_public_rejection('preferred_posting_language', 'ja', 'unknown_key')
    end

    it 'stores an unrecognized new-features policy string' do
      put :update, params: { user: { setting_new_features_policy: 'nope' } }

      expect(stored(user, 'new_features_policy').value).to eq 'nope'
      expect(stored(user, 'new_features_policy').value).to be_a(String)
      expect_public_rejection('new_features_policy', 'nope', 'invalid_value')
    end

    it 'writes the legacy cache on a same-value resubmit without moving updated_at' do
      user.settings['default_privacy'] = 'unlisted'
      row = stored(user, 'default_privacy')
      row.update_columns(updated_at: 3.hours.ago)
      stamp = row.reload.updated_at
      key = Setting.cache_key('default_privacy', user)
      writes = []
      allow(Rails.cache).to receive(:write).and_wrap_original do |method, cache_key, value, *rest|
        writes << [cache_key, value]
        method.call(cache_key, value, *rest)
      end

      put :update, params: { user: { setting_default_privacy: 'unlisted' } }

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(row.reload.updated_at).to eq stamp
      expect(row.value).to eq 'unlisted'
      expect(writes).to include([key, 'unlisted'])
      expect(UserPreferences::Revision.current(user.id)).to eq 0
    end

    it 'keeps earlier keys when a later key raises and does not save the rest' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)
      allow_any_instance_of(Settings::ScopedSettings).to receive(:[]=).and_wrap_original do |method, key, value|
        raise 'content_font_size failed' if key.to_s == 'content_font_size'

        method.call(key, value)
      end

      expect do
        put :update, params: {
          user: {
            locale: 'en',
            setting_default_privacy: 'unlisted',
            setting_default_language: 'de',
            setting_content_font_size: '18',
            setting_info_font_size: '12',
            setting_reduce_motion: '1',
            setting_noindex: '1',
          },
        }
      end.to raise_error(RuntimeError, 'content_font_size failed')

      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'default_language').value).to eq 'de'
      expect(stored(user, 'content_font_size')).to be_nil
      expect(stored(user, 'info_font_size')).to be_nil
      expect(stored(user, 'reduce_motion')).to be_nil
      expect(stored(user, 'noindex')).to be_nil
      expect(User.find(user.id).locale).to eq 'ja'
    end

    it 'distributes when a profile key is present even if that value does not change' do
      expect(ActivityPub::UpdateDistributionWorker).to receive(:perform_async).with(user.account.id)

      put :update, params: { user: { setting_noindex: '0', setting_default_privacy: 'unlisted' } }

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'noindex').value).to be false
    end

    it 'does not distribute an other-screen save that contains only the nine keys' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)

      put :update, params: {
        user: {
          setting_default_privacy: 'unlisted',
          setting_default_sensitive: '1',
          setting_default_language: 'de',
          setting_new_features_policy: 'tester',
        },
      }

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(stored(user, 'new_features_policy').value).to eq 'tester'
    end

    it 'keeps saved settings when the following user-column update fails' do
      user.settings['max_frequently_used_emojis'] = 0
      expect(ActivityPub::UpdateDistributionWorker).to receive(:perform_async).with(user.account.id)

      put :update, params: {
        user: {
          locale: 'en',
          setting_default_privacy: 'unlisted',
          setting_noindex: '1',
        },
      }

      expect(response).to have_http_status(200)
      expect(response).not_to be_redirect
      expect(User.find(user.id).locale).to eq 'ja'
      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'noindex').value).to be true
    end

    it 'keeps high-risk settings outside the nine-key writer contract' do
      put :update, params: {
        user: {
          setting_noindex: '1',
          setting_hide_statuses_count: '1',
          setting_enable_reaction: '0',
        },
      }

      expect(stored(user, 'noindex').value).to be true
      expect(stored(user, 'hide_statuses_count').value).to be true
      expect(stored(user, 'enable_reaction').value).to be false
      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
      expect_public_rejection('noindex', false, 'unknown_key')
      expect_public_rejection('hide_statuses_count', true, 'unknown_key')
      expect_public_rejection('enable_reaction', false, 'unknown_key')
    end

    it 'drops a non-scalar privacy value and an unknown setting key on the form' do
      put :update, params: {
        user: {
          setting_default_privacy: { bad: 'direct' },
          setting_not_a_real_preference: 'x',
          setting_default_language: 'de',
        },
      }

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(stored(user, 'default_privacy')).to be_nil
      expect(stored(user, 'not_a_real_preference')).to be_nil
      expect(stored(user, 'default_language').value).to eq 'de'
      expect_public_rejection('default_privacy', { 'bad' => 'direct' }, 'invalid_type')
    end
  end

  describe Settings::Preferences::SafetyController, type: :controller do
    let(:user) { Fabricate(:user) }

    before { sign_in user, scope: :user }

    it 'saves a posted nine-key and a prohibited-operation key through the shared action' do
      put :update, params: { user: { setting_content_font_size: '18', setting_disable_post: '1' } }

      expect(response).to redirect_to(settings_preferences_safety_path)
      expect(stored(user, 'content_font_size').value).to eq '18'
      expect(stored(user, 'content_font_size').value).to be_a(String)
      expect(stored(user, 'disable_post').value).to be true
      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect_public_rejection('disable_post', true, 'unknown_key')
    end
  end

  describe Settings::Preferences::NotificationsController, type: :controller do
    let(:user) { Fabricate(:user) }

    before { sign_in user, scope: :user }

    it 'keeps interaction filters on the decorator and outside the writer contract' do
      put :update, params: { user: { interactions: { must_be_follower: '0' } } }

      expect(response).to redirect_to(settings_preferences_notifications_path)
      expect(User.find(user.id).settings['interactions']['must_be_follower']).to be false
      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect_public_rejection('interactions', { 'must_be_follower' => false }, 'unknown_key')
    end
  end

  describe Api::V1::Accounts::CredentialsController, type: :controller do
    let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
    let(:scopes) { 'write:accounts' }
    let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

    before do
      allow(controller).to receive(:doorkeeper_token) { token }
      allow(VerifyAccountLinksWorker).to receive(:perform_async)
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
      allow(AuthorizeFollowWorker).to receive(:push_bulk)
    end

    it 'materializes omitted privacy and sensitive when only language is sent' do
      patch :update, params: { source: { language: 'de' } }, as: :json

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_privacy').value).to eq 'public'
      expect(stored(user, 'default_sensitive').value).to be false
      expect(stored(user, 'default_language').value).to eq 'de'
      expect(stored(user, 'preferred_posting_language')).to be_nil
      expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(user.account.id)
      expect(UserPreferences::Revision.current(user.id)).to eq 0
    end

    it 'fills privacy from the getter after the account update, so an unlock stores public' do
      user.account.update!(locked: true)

      patch :update, params: { locked: false, source: { language: 'de' } }, as: :json

      expect(response).to have_http_status(200)
      expect(user.account.reload.locked).to be false
      expect(stored(user, 'default_privacy').value).to eq 'public'
      expect(stored(user, 'default_sensitive').value).to be false
      expect(stored(user, 'default_language').value).to eq 'de'
    end

    it 'does not replace stored privacy when source privacy is null, and still fills omitted sensitive' do
      user.settings['default_privacy'] = 'direct'

      patch :update, params: { source: { privacy: nil } }, as: :json

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(User.find(user.id).setting_default_privacy).to eq 'direct'
      expect(stored(user, 'default_sensitive').value).to be false
      expect(stored(user, 'default_language')).to be_nil
      expect_public_rejection('default_privacy', nil, 'null_value')
    end

    it 'stores direct from credentials while the public contract rejects it' do
      patch :update, params: { source: { privacy: 'direct', sensitive: true, language: 'en' } }, as: :json

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(stored(user, 'default_sensitive').value).to be true
      expect(stored(user, 'default_language').value).to eq 'en'
      expect_public_rejection('default_privacy', 'direct', 'invalid_value')
    end

    it 'keeps the account update when the following settings save fails' do
      user.account.update!(locked: true)
      follower = Fabricate(:account)
      Fabricate(:follow_request, account: follower, target_account: user.account)
      captured = nil
      allow(AuthorizeFollowWorker).to receive(:push_bulk) do |requests, &block|
        captured = requests.map { |request| block.call(request) }
      end
      allow_any_instance_of(UserSettingsDecorator).to receive(:update).and_raise('settings failed')

      expect do
        patch :update, params: {
          display_name: 'Opened',
          locked: false,
          source: { language: 'de' },
        }, as: :json
      end.to raise_error(RuntimeError, 'settings failed')

      expect(user.account.reload.display_name).to eq 'Opened'
      expect(user.account.reload.locked).to be false
      expect(stored(user, 'default_language')).to be_nil
      expect(stored(user, 'default_privacy')).to be_nil
      expect(captured).to eq [[follower.id, user.account.id]]
      expect(VerifyAccountLinksWorker).to have_received(:perform_async).with(user.account.id)
      expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
    end

    it 'currently stores a non-scalar source value that the legacy path must not keep' do
      patch :update, params: {
        source: {
          privacy: { bad: 'direct' },
          language: ['ja-JP'],
        },
      }, as: :json

      expect(response).to have_http_status(200)
      privacy = stored(user, 'default_privacy').value
      expect(privacy).to be_a(ActionController::Parameters)
      expect(privacy['bad']).to eq 'direct'
      expect(privacy).not_to be_permitted
      expect(stored(user, 'default_language').value).to eq ['ja-JP']
      expect(stored(user, 'default_language').value).to be_a(Array)
      expect(stored(user, 'default_sensitive').value).to be false
      expect_public_rejection('default_privacy', { 'bad' => 'direct' }, 'invalid_type')
      expect_public_rejection('default_language', ['ja-JP'], 'invalid_type')
    end

    it 'saves source with the write scope and does not require write:preferences' do
      access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write')
      allow(controller).to receive(:doorkeeper_token) { access_token }

      patch :update, params: { source: { language: 'de' } }, as: :json

      expect(access_token.scopes.to_s).not_to include('write:preferences')
      expect(response).to have_http_status(200)
      expect(stored(user, 'default_language').value).to eq 'de'
    end

    it 'saves source with write:accounts' do
      patch :update, params: { source: { privacy: 'unlisted' } }, as: :json

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
    end

    it 'rejects a token whose only scope is write:preferences' do
      access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences')
      allow(controller).to receive(:doorkeeper_token) { access_token }

      patch :update, params: { display_name: 'Nope', source: { language: 'de' } }, as: :json

      expect(response).to have_http_status(403)
      expect(user.account.reload.display_name).not_to eq 'Nope'
      expect(stored(user, 'default_language')).to be_nil
    end
  end
end
