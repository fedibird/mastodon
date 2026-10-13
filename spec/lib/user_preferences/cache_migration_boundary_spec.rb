# frozen_string_literal: true

require 'rails_helper'

# Locks the P2-4B boundary. Decorator and ScopedSettings do not move
# user_preference_revisions, and getters still use Setting.cache_key.
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
    it 'keeps revision unchanged when the decorator saves all nine keys' do
      user = Fabricate(:user)
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

      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
      expect(stored(user, 'default_privacy').value).to eq 'unlisted'
      expect(stored(user, 'default_sensitive').value).to be true
      expect(stored(user, 'reduce_motion').value).to be true
      expect(stored(user, 'content_font_size').value).to eq '16'
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

    it 'fetches the nine getters through the legacy cache key' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, cache_key, *args, &block|
        fetched << cache_key
        method.call(cache_key, *args, &block)
      end

      expect(user.setting_default_privacy).to eq 'private'
      expect(user.setting_default_sensitive).to be false
      expect(user.setting_default_language).to be_nil
      user.setting_show_translation_bar
      user.setting_translation_preferred_mode
      user.setting_new_features_policy
      user.setting_content_font_size
      user.setting_info_font_size
      user.setting_reduce_motion

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
        expect(fetched).to include(legacy_key(user, var))
        expect(Setting.cache_key(var, user)).to eq legacy_key(user, var)
      end
      expect(fetched.grep(%r{/rev/})).to be_empty
      expect(sql_log { user.setting_reduce_motion }.grep(/user_preference_revisions/)).to be_empty
    end

    it 'reads the database from Reader when the legacy cache has another value' do
      user = Fabricate(:user)
      user.settings['default_sensitive'] = false
      Rails.cache.write(Setting.cache_key('default_sensitive', user), true)

      expect(user.setting_default_sensitive).to be true

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

    it 'advances revision and deletes only the legacy cache key' do
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
        legacy_key(user, 'default_privacy')
      )
      expect(deleted.grep(%r{/rev/})).to be_empty

      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, cache_key, *args, &block|
        fetched << cache_key
        method.call(cache_key, *args, &block)
      end
      expect(user.setting_reduce_motion).to be true
      expect(fetched).to include(legacy_key(user, 'reduce_motion'))
      expect(fetched.grep(%r{/rev/})).to be_empty
    ensure
      discard_user(user)
    end
  end
end
