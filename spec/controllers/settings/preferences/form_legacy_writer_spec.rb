# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'preference form legacy writer' do
  self.use_transactional_tests = false

  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def revision(user)
    UserPreferences::Revision.current(user.id)
  end

  def legacy_key(user, var)
    Setting.cache_key(var, user)
  end

  def cache_source(frames)
    return 'rewrite_cache' if frames.any? { |frame| frame.include?('rewrite_cache') }
    return 'cache_deletion' if frames.any? { |frame| frame.include?('cache_deletion.rb') }

    'other'
  end

  def observe
    events = []
    messages = []
    sql_committed = false
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if sql.include?('SCHEMA')
      next unless sql.match?(/\A\s*COMMIT\b/i)

      sql_committed = true
      events << { op: 'commit' }
    end
    allow(Rails.cache).to receive(:write).and_wrap_original do |method, key, value, *rest|
      if key.to_s.include?('rails_settings_cached')
        events << { op: 'write', key: key, value: value, source: cache_source(caller), after_sql_commit: sql_committed }
      end
      method.call(key, value, *rest)
    end
    allow(Rails.cache).to receive(:delete).and_wrap_original do |method, key, *rest|
      if key.to_s.include?('rails_settings_cached')
        events << { op: 'delete', key: key, source: cache_source(caller), after_sql_commit: sql_committed }
      end
      method.call(key, *rest)
    end
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |redis|
        block.call(RecordingPublisher.new(redis, messages, [], lambda {
          events << { op: 'notify', after_sql_commit: sql_committed }
        }))
      end
    end
    yield events, messages
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  describe Settings::Preferences::AppearanceController, type: :controller do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }
    after { discard_user(user) }

    it 'stores font sizes as strings and advances revision once per key' do
      put :update, params: { user: { setting_content_font_size: '18', setting_info_font_size: '16' } }

      expect(response).to redirect_to(settings_preferences_appearance_path)
      expect(stored(user, 'content_font_size').value).to eq '18'
      expect(stored(user, 'info_font_size').value).to eq '16'
      expect(stored(user, 'preferred_posting_language')).to be_nil
      expect(revision(user)).to eq 2
    end

    it 'keeps the boolean cast for reduce motion' do
      put :update, params: { user: { setting_reduce_motion: '1' } }

      expect(stored(user, 'reduce_motion').value).to be true
      expect(revision(user)).to eq 1
    end

    it 'normalizes the translation bar with the policy snapshotted before the save' do
      user.settings['new_features_policy'] = 'default'

      put :update, params: {
        user: {
          setting_show_translation_bar: 'nope',
          setting_new_features_policy: 'conservative',
        },
      }

      expect(stored(user, 'show_translation_bar').value).to eq 'target'
      expect(stored(user, 'new_features_policy').value).to eq 'conservative'
    end

    it 'keeps a nil policy snapshot when the submitted policy is tester' do
      user.settings['new_features_policy'] = nil

      put :update, params: {
        user: {
          setting_show_translation_bar: 'nope',
          setting_new_features_policy: 'tester',
        },
      }

      expect(stored(user, 'show_translation_bar').value).to eq 'target'
      expect(stored(user, 'new_features_policy').value).to eq 'tester'
    end
  end

  describe Settings::Preferences::OtherController, type: :controller do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }
    after { discard_user(user) }

    it 'stores privacy, language, sensitive, and policy from the other form' do
      put :update, params: {
        user: {
          setting_default_privacy: 'direct',
          setting_default_language: 'ja-JP',
          setting_default_sensitive: '0',
          setting_new_features_policy: 'nope',
        },
      }

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(stored(user, 'default_language').value).to eq 'ja-JP'
      expect(stored(user, 'default_sensitive').value).to be false
      expect(stored(user, 'new_features_policy').value).to eq 'nope'
      expect(stored(user, 'preferred_posting_language')).to be_nil
      expect(revision(user)).to eq 4
    end

    it 'skips nil and stores an empty boolean as a nil row' do
      user.settings['default_privacy'] = 'unlisted'
      put :update, params: {
        user: {
          setting_default_privacy: nil,
          setting_default_sensitive: '',
          setting_default_language: 'de',
        },
      }, as: :json

      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'default_sensitive').value).to be_nil
      expect(stored(user, 'default_language').value).to eq 'de'
      expect(revision(user)).to eq 2
    end

    it 'does not move revision or cache when the same value is sent again' do
      put :update, params: { user: { setting_default_privacy: 'unlisted' } }
      row = stored(user, 'default_privacy')
      row.update_columns(updated_at: 3.hours.ago)
      stamp = row.reload.updated_at
      key = legacy_key(user, 'default_privacy')
      Rails.cache.write(key, 'sentinel')

      events = nil
      messages = nil
      observe do |seen, published|
        put :update, params: { user: { setting_default_privacy: 'unlisted' } }
        events = seen
        messages = published
      end

      expect(response).to redirect_to(settings_preferences_other_path)
      expect(revision(user)).to eq 1
      expect(row.reload.updated_at).to eq stamp
      expect(Rails.cache.read(key)).to eq 'sentinel'
      expect(events.select { |event| event[:key] == key || event[:op] == 'notify' }).to eq []
      expect(messages).to eq []
    end

    it 'publishes one committed event per changed key, in decorator order' do
      events = nil
      messages = nil
      observe do |seen, published|
        put :update, params: { user: { setting_default_privacy: 'unlisted', setting_default_language: 'de' } }
        events = seen
        messages = published
      end

      privacy = legacy_key(user, 'default_privacy')
      language = legacy_key(user, 'default_language')
      relevant = []
      events.each do |event|
        next unless [privacy, language].include?(event[:key]) || %w(commit notify).include?(event[:op])

        relevant << event
        break if event[:op] == 'notify' && relevant.count { |item| item[:op] == 'notify' } == 2
      end
      expect(relevant.map { |event| event[:op] }).to eq(
        %w(commit write delete notify commit write delete notify)
      ), events.inspect
      expect(relevant[1]).to include(key: privacy, source: 'rewrite_cache', value: 'unlisted', after_sql_commit: true)
      expect(relevant[2]).to include(key: privacy, source: 'cache_deletion', after_sql_commit: true)
      expect(relevant[5]).to include(key: language, source: 'rewrite_cache', value: 'de', after_sql_commit: true)
      expect(relevant[6]).to include(key: language, source: 'cache_deletion', after_sql_commit: true)
      expect(revision(user)).to eq 2
      expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'changed_keys') }).to eq(
        [['user.default_privacy'], ['user.default_language']]
      )
      expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'revision') }).to eq %w(1 2)
      expect(Rails.cache.exist?(privacy)).to be false
      expect(Rails.cache.exist?(language)).to be false
    end

    it 'keeps earlier commits when a later nine-key save rolls back' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)
      events = nil
      messages = nil

      expect do
        observe do |seen, published|
          events = seen
          messages = published
          allow_any_instance_of(Setting).to receive(:save!).and_wrap_original do |method, *args|
            record = method.receiver
            method.call(*args)
            raise 'content_font_size failed' if record.var == 'content_font_size'
          end
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
        end
      end.to raise_error(RuntimeError, 'content_font_size failed')

      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'default_language').value).to eq 'de'
      expect(stored(user, 'content_font_size')).to be_nil
      expect(stored(user, 'info_font_size')).to be_nil
      expect(stored(user, 'reduce_motion')).to be_nil
      expect(stored(user, 'noindex')).to be_nil
      expect(User.find(user.id).locale).to eq 'ja'
      expect(revision(user)).to eq 2
      expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'changed_keys') }).to eq(
        [['user.default_privacy'], ['user.default_language']]
      )
      expect(events.select { |event| event[:key] == legacy_key(user, 'content_font_size') }).to eq []
    end
  end

  describe Settings::Preferences::SafetyController, type: :controller do
    let(:user) { Fabricate(:user) }

    before { sign_in user, scope: :user }
    after { discard_user(user) }

    it 'advances revision for a font size posted to the shared safety action' do
      put :update, params: { user: { setting_content_font_size: '18', setting_disable_post: '1' } }

      expect(response).to redirect_to(settings_preferences_safety_path)
      expect(stored(user, 'content_font_size').value).to eq '18'
      expect(stored(user, 'disable_post').value).to be true
      expect(revision(user)).to eq 1
    end
  end

  describe Settings::Preferences::NotificationsController, type: :controller do
    let(:user) { Fabricate(:user) }

    before { sign_in user, scope: :user }
    after { discard_user(user) }

    it 'keeps nested interaction settings on the old path' do
      put :update, params: { user: { interactions: { must_be_follower: '0' } } }

      expect(response).to redirect_to(settings_preferences_notifications_path)
      expect(User.find(user.id).settings['interactions']['must_be_follower']).to be false
      expect(revision(user)).to eq 0
    end
  end

  describe Settings::Preferences::OtherController, 'profile distribution', type: :controller do
    let(:user) { Fabricate(:user, locale: 'ja') }

    before { sign_in user, scope: :user }
    after { discard_user(user) }

    it 'does not distribute when only nine keys are submitted' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)

      put :update, params: { user: { setting_default_privacy: 'unlisted' } }

      expect(revision(user)).to eq 1
    end

    it 'distributes when a profile key is present even if that value does not change' do
      expect(ActivityPub::UpdateDistributionWorker).to receive(:perform_async).with(user.account.id)

      put :update, params: { user: { setting_noindex: '0', setting_default_privacy: 'unlisted' } }

      expect(stored(user, 'noindex').value).to be false
      expect(revision(user)).to eq 1
    end

    it 'keeps the saved setting and a queued distribution when the user column update fails' do
      user.settings['max_frequently_used_emojis'] = 0
      expect(ActivityPub::UpdateDistributionWorker).to receive(:perform_async).with(user.account.id)

      put :update, params: { user: { locale: 'en', setting_default_privacy: 'unlisted', setting_noindex: '1' } }

      expect(response).to have_http_status(200)
      expect(response).not_to be_redirect
      expect(User.find(user.id).locale).to eq 'ja'
      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'noindex').value).to be true
    end
  end

  describe Settings::Preferences::AppearanceController, 'invalid input', type: :controller do
    render_views

    let(:user) { Fabricate(:user, locale: 'ja') }

    before do
      sign_in user, scope: :user
      allow_any_instance_of(Webpacker::Manifest).to receive(:lookup!) do |*_args, **kwargs|
        kwargs[:with_integrity] ? ['/packs-test/dummy.js', nil] : '/packs-test/dummy.js'
      end
    end

    after { discard_user(user) }

    it 'redisplays the form and keeps the earlier key when a later value is the wrong type' do
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)

      put :update, params: {
        user: {
          locale: 'en',
          setting_default_privacy: 'direct',
          setting_content_font_size: 18,
        },
      }, as: :json

      expect(response).to have_http_status(422)
      expect(response.body).to include(I18n.t('preferences.invalid_input', key: 'content_font_size', locale: :ja))
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(stored(user, 'content_font_size')).to be_nil
      expect(User.find(user.id).locale).to eq 'ja'
      expect(revision(user)).to eq 1
    end
  end

  describe Api::V1::Accounts::CredentialsController, type: :controller do
    let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'carol')) }
    let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:accounts') }

    before do
      allow(controller).to receive(:doorkeeper_token) { token }
      allow(VerifyAccountLinksWorker).to receive(:perform_async)
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
    end

    after { discard_user(user) }

    it 'keeps credentials and the undecorated settings path off revision' do
      UserSettingsDecorator.new(user).update('setting_default_privacy' => 'direct')
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(revision(user)).to eq 0

      patch :update, params: { source: { privacy: 'direct', language: 'ja-JP' } }, as: :json

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_language').value).to eq 'ja-JP'
      expect(revision(user)).to eq 0
    end
  end
end
