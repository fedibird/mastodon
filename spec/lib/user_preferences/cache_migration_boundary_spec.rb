# frozen_string_literal: true

require 'rails_helper'

# Locks the cache boundary after P2-4D. User nine-key getters read
# <Setting.cache_key>/rev/<revision>. ScopedSettings#[]= still writes the
# legacy key and does not move revision. A decorator without a LegacyWriter
# no longer saves the nine keys.
RSpec.describe 'preference cache revision boundary' do
  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def store_setting(user, var, value)
    record = Setting.unscoped.find_or_initialize_by(thing_type: 'User', thing_id: user.id, var: var)
    record.value = value
    record.save!
    record.update_columns(updated_at: 3.hours.ago)
    record.reload
  end

  def sql_log
    captured = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      captured << sql unless sql.include?('SCHEMA')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    captured
  end

  def legacy_key(user, var)
    ['rails_settings_cached', Setting.cache_prefix_by_startup, "User-#{user.id}", var].join('/')
  end

  describe 'current readers and non-writer saves' do
    it 'refuses the nine keys before saving when the decorator has no legacy writer' do
      user = Fabricate(:user)

      expect do
        UserSettingsDecorator.new(user).update(
          'setting_default_privacy' => 'unlisted',
          'setting_default_language' => 'de',
          'setting_translation_preferred_mode' => 'bilingual',
          'setting_show_translation_bar' => 'always',
          'setting_new_features_policy' => 'tester',
          'setting_content_font_size' => '16',
          'setting_info_font_size' => '14',
          'setting_default_sensitive' => '1',
          'setting_reduce_motion' => '1'
        )
      end.to raise_error(UserSettingsDecorator::MissingLegacyWriter)

      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
      expect(stored(user, 'default_privacy')).to be_nil
      expect(stored(user, 'default_sensitive')).to be_nil
      expect(stored(user, 'reduce_motion')).to be_nil
      expect(stored(user, 'content_font_size')).to be_nil
    end

    it 'writes the legacy cache key from ScopedSettings and does not advance revision' do
      user = Fabricate(:user)
      key = Setting.cache_key('content_font_size', user)
      written = []
      allow(Rails.cache).to receive(:write).and_wrap_original do |method, cache_key, value, *rest|
        written << [cache_key, value]
        method.call(cache_key, value, *rest)
      end

      user.settings['content_font_size'] = '17'

      expect(key).to eq legacy_key(user, 'content_font_size')
      expect(key).not_to include('/rev/')
      expect(written).to include([key, '17'])
      expect(Rails.cache.read(key)).to eq '17'
      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
    end

    it 'fetches the nine getters through the revision cache key' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, cache_key, *args, &block|
        fetched << cache_key
        method.call(cache_key, *args, &block)
      end

      selects = sql_log do
        UserPreferences::RevisionMemo.scope do
          expect(user.setting_default_privacy).to eq 'private'
          expect(user.setting_default_sensitive).to be false
          expect(user.setting_default_language).to be_nil
          user.setting_show_translation_bar
          user.setting_translation_preferred_mode
          user.setting_new_features_policy
          user.setting_content_font_size
          user.setting_info_font_size
          user.setting_reduce_motion
        end
      end

      %w(
        default_privacy
        default_sensitive
        default_language
        show_translation_bar
        translation_preferred_mode
        new_features_policy
        content_font_size
        info_font_size
        reduce_motion
      ).each do |var|
        expect(fetched).to include(UserPreferences::CacheKey.for_revision(var, user, 0))
        expect(fetched).not_to include(legacy_key(user, var))
      end
      expect(selects.grep(/FROM "user_preference_revisions"/).size).to eq 1
      expect(selects.grep(/FROM "settings"/).size).to eq 9
    end

    it 'does not read a legacy key or a different revision key' do
      user = Fabricate(:user)
      legacy = Setting.cache_key('default_privacy', user)
      other = UserPreferences::CacheKey.for_revision('default_privacy', user, 7)
      Rails.cache.write(legacy, 'from-legacy-key')
      Rails.cache.write(other, 'from-revision-key')

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_privacy).to eq 'public'
        expect(user.setting_default_privacy).not_to eq 'from-legacy-key'
        expect(user.setting_default_privacy).not_to eq 'from-revision-key'
      end
    end

    it 'leaves a revision cache key alone when a high-risk setting is saved' do
      user = Fabricate(:user)
      legacy = Setting.cache_key('disable_post', user)
      revision = "#{legacy}/rev/1"
      Rails.cache.write(revision, 'sentinel')

      user.settings['disable_post'] = true

      expect(Rails.cache.read(legacy)).to be true
      expect(Rails.cache.read(revision)).to eq 'sentinel'
      expect(UserPreferences::Revision.current(user.id)).to eq 0
    end

    it 'reads the database from Reader when the legacy cache has another value' do
      user = Fabricate(:user)
      user.settings['default_sensitive'] = false
      Rails.cache.write(Setting.cache_key('default_sensitive', user), true)

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_sensitive).to be false
      end

      value = UserPreferences::Reader.new(user).get('default_sensitive')
      expect(value.state).to eq :present
      expect(value.configured).to be false
      expect(value.effective).to be false
      expect(stored(user, 'default_sensitive').value).to be false
    end

    it 'does not select revision while Reader loads the stored rows' do
      user = Fabricate(:user)
      store_setting(user, 'default_privacy', 'unlisted')
      queries = sql_log { UserPreferences::Reader.new(user).read }

      expect(queries.count { |sql| sql.include?('settings') }).to eq 1
      expect(queries.grep(/user_preference_revisions/)).to be_empty
    end

    it 'does not persist the privacy fallback when the stored value is nil' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      record = store_setting(user, 'default_privacy', nil)
      stamp = record.updated_at

      expect(user.setting_default_privacy).to eq 'private'
      value = UserPreferences::Reader.new(user).get('default_privacy')
      expect(value.state).to eq :nil
      expect(value.configured).to be_nil
      expect(value.effective).to eq 'private'

      fresh = record.reload
      expect(fresh.value).to be_nil
      expect(fresh.updated_at).to eq stamp
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_privacy').count).to eq 1
    end

    it 'does not repair legacy invalid rows on read' do
      user = Fabricate(:user, locale: 'ja')
      other = Fabricate(:user)
      rows = {
        'default_privacy' => '',
        'default_language' => 'invalid',
        'show_translation_bar' => 'nope',
        'translation_preferred_mode' => 'original',
        'content_font_size' => 'invalid',
        'info_font_size' => '18',
      }
      saved = rows.to_h { |var, value| [var, store_setting(user, var, value)] }
      direct = store_setting(other, 'default_privacy', 'direct')
      stamps = saved.transform_values(&:updated_at)
      direct_stamp = direct.updated_at

      expect(user.setting_default_privacy).to eq ''
      expect(user.setting_default_language).to eq 'invalid'
      expect(user.setting_show_translation_bar).to eq 'target'
      expect(user.setting_translation_preferred_mode).to eq 'translated'
      expect(user.setting_content_font_size).to eq 'invalid'
      expect(user.setting_info_font_size).to eq '18'
      expect(other.setting_default_privacy).to eq 'direct'

      reader = UserPreferences::Reader.new(user)
      expect(reader.get('default_privacy').configured).to eq ''
      expect(reader.get('default_language').configured).to eq 'invalid'
      expect(reader.get('show_translation_bar').configured).to eq 'nope'
      expect(reader.get('show_translation_bar').effective).to eq 'target'
      expect(reader.get('translation_preferred_mode').configured).to eq 'original'
      expect(reader.get('content_font_size').configured).to eq 'invalid'
      expect(reader.get('info_font_size').configured).to eq '18'
      expect(reader.get('info_font_size').public_value).to eq 18
      expect(UserPreferences::Reader.new(other).get('default_privacy').configured).to eq 'direct'

      rows.each do |var, value|
        fresh = saved[var].reload
        expect(fresh.value).to eq value
        expect(fresh.updated_at).to eq stamps[var]
      end
      expect(direct.reload.value).to eq 'direct'
      expect(direct.updated_at).to eq direct_stamp
    end
  end

  describe 'writer' do
    self.use_transactional_tests = false

    def discard_user(user)
      return unless user&.id

      Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
      UserPreferenceRevision.where(user_id: user.id).delete_all
      Account.where(id: user.account_id).delete_all
      User.where(id: user.id).delete_all
    end

    it 'advances revision and deletes the legacy key and the committed revision key' do
      user = Fabricate(:user)
      deleted = []
      allow(Rails.cache).to receive(:delete).and_wrap_original do |method, cache_key, *args|
        deleted << cache_key
        method.call(cache_key, *args)
      end

      result = UserPreferences::Writer.new(user).apply(
        updates: { 'reduce_motion' => true, 'default_privacy' => 'private' }
      )

      expect(result.before_revision).to eq 0
      expect(result.after_revision).to eq 1
      expect(UserPreferences::Revision.current(user.id)).to eq 1
      expect(deleted).to contain_exactly(
        legacy_key(user, 'reduce_motion'),
        UserPreferences::CacheKey.for_revision('reduce_motion', user, 1),
        legacy_key(user, 'default_privacy'),
        UserPreferences::CacheKey.for_revision('default_privacy', user, 1)
      )

      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, cache_key, *args, &block|
        fetched << cache_key
        method.call(cache_key, *args, &block)
      end
      expect(user.setting_reduce_motion).to be true
      expect(fetched).to include(UserPreferences::CacheKey.for_revision('reduce_motion', user, 1))
      expect(fetched).not_to include(legacy_key(user, 'reduce_motion'))
    ensure
      discard_user(user)
    end
  end
end
