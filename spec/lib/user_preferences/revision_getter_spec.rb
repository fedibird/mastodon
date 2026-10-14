# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'revision getter' do
  def revision_selects(sql)
    sql.grep(/FROM "user_preference_revisions"/)
  end

  def settings_selects(sql)
    sql.grep(/FROM "settings"/)
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

  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  describe UserPreferences::RevisionMemo do
    let(:user) { Fabricate(:user) }
    let(:other) { Fabricate(:user) }

    it 'reads revision 0 once per user inside a scope and again in the next scope' do
      selects = sql_log do
        described_class.scope do
          expect(described_class.revision_for(user.id)).to eq 0
          expect(described_class.revision_for(user.id)).to eq 0
          expect(described_class.revision_for(other.id)).to eq 0
        end
      end
      expect(revision_selects(selects).size).to eq 2

      again = sql_log { described_class.scope { described_class.revision_for(user.id) } }
      expect(revision_selects(again).size).to eq 1
    end

    it 'drops the memo when the scope raises and does not keep it outside a scope' do
      expect do
        described_class.scope do
          described_class.revision_for(user.id)
          raise 'boom'
        end
      end.to raise_error('boom')

      outside = sql_log do
        described_class.revision_for(user.id)
        described_class.revision_for(user.id)
      end
      expect(revision_selects(outside).size).to eq 2
    end

    it 'keeps the outer memo when an inner scope ends' do
      described_class.scope do
        described_class.revision_for(user.id)
        described_class.scope { described_class.revision_for(user.id) }
        nested = sql_log { described_class.revision_for(user.id) }
        expect(revision_selects(nested)).to be_empty
      end
    end

    it 'does not invent revision 0 when PostgreSQL raises' do
      allow(UserPreferences::Revision).to receive(:current).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect do
        described_class.scope { described_class.revision_for(user.id) }
      end.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect do
        described_class.scope { described_class.revision_for(user.id) }
      end.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  describe Mastodon::RackMiddleware do
    let(:user) { Fabricate(:user) }

    it 'uses a fresh revision memo for each request, including after an error' do
      calls = 0
      app = lambda do |_env|
        calls += 1
        UserPreferences::RevisionMemo.revision_for(user.id)
        raise 'request failed' if calls == 1

        [200, {}, ['ok']]
      end
      middleware = described_class.new(app)

      expect { middleware.call({}) }.to raise_error('request failed')
      selects = sql_log { middleware.call({}) }
      expect(revision_selects(selects).size).to eq 1
    end
  end

  describe Mastodon::SidekiqMiddleware do
    let(:user) { Fabricate(:user) }

    it 'does not reuse the previous job revision on the same thread' do
      middleware = described_class.new
      middleware.call { UserPreferences::RevisionMemo.revision_for(user.id) }
      UserPreferenceRevision.create!(user_id: user.id, revision: 8)

      value = nil
      selects = sql_log do
        middleware.call { value = UserPreferences::RevisionMemo.revision_for(user.id) }
      end

      expect(value).to eq 8
      expect(revision_selects(selects).size).to eq 1
    end
  end

  describe 'nine key reads' do
    let(:user) { Fabricate(:user, account: Fabricate(:account, locked: true)) }

    it 'reads revision keys, skips the legacy key, and selects settings only on a miss' do
      legacy = Setting.cache_key('default_sensitive', user)
      Rails.cache.write(legacy, true)
      revision = UserPreferences::CacheKey.for_revision('default_sensitive', user, 0)

      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, key, *args, &block|
        fetched << key
        method.call(key, *args, &block)
      end

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_sensitive).to be false
        hit = sql_log { expect(user.setting_default_sensitive).to be false }
        expect(settings_selects(hit)).to be_empty
        expect(revision_selects(hit)).to be_empty
      end

      expect(fetched).to include(revision)
      expect(fetched).not_to include(legacy)
      expect(Rails.cache.read(revision)).to be false
    end

    it 'keeps a nil row and does not write the setting back' do
      user.settings['default_language'] = nil
      row = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'default_language')
      stamp = row.updated_at

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_language).to be_nil
      end

      expect(row.reload.updated_at).to eq stamp
      expect(row.value).to be_nil
    end

    it 'still completes privacy and translation from the raw cached value' do
      user.settings['default_privacy'] = nil
      user.settings['show_translation_bar'] = 'nope'
      user.settings['new_features_policy'] = 'default'

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_privacy).to eq 'private'
        expect(user.setting_show_translation_bar).to eq 'target'
      end
      expect(Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'show_translation_bar').value).to eq 'nope'
    end

    it 'keeps high-risk and nested settings on the legacy cache key' do
      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, key, *args, &block|
        fetched << key
        method.call(key, *args, &block)
      end

      UserPreferences::RevisionMemo.scope do
        user.setting_disable_post
        user.settings.notification_emails
      end

      expect(fetched).to include(Setting.cache_key('disable_post', user))
      expect(fetched).to include(Setting.cache_key('notification_emails', user))
      expect(fetched.none? { |key| key.to_s.include?('/rev/') }).to be true
    end

    it 'reads a site setting through the unscoped cache key' do
      key = Setting.cache_key('registrations_mode', nil)
      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, cache_key, *args, &block|
        fetched << cache_key
        method.call(cache_key, *args, &block)
      end

      selects = sql_log { Setting.registrations_mode }

      expect(key).not_to include('/rev/')
      expect(fetched).to include(key)
      expect(fetched.none? { |cache_key| cache_key.to_s.include?('/rev/') }).to be true
      expect(revision_selects(selects)).to be_empty
    end
  end

  describe 'cache and database failures' do
    let(:user) { Fabricate(:user) }

    it 'returns the database value when the revision cache write returns false' do
      legacy = Setting.cache_key('content_font_size', user)
      Rails.cache.write(legacy, 99)
      allow(Rails.cache).to receive(:write).and_return(false)

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_content_font_size).to eq 15
      end
      expect(Rails.cache.read(legacy)).to eq 99
    end

    it 'returns the database value when RedisCacheStore treats Redis::BaseError as a miss' do
      legacy = Setting.cache_key('default_sensitive', user)
      Rails.cache.write(legacy, true)
      seen = []
      client = Object.new
      client.define_singleton_method(:with) { |&block| block.call(self) }
      client.define_singleton_method(:get) do |key|
        seen << key
        raise Redis::BaseError, 'down'
      end
      client.define_singleton_method(:set) { |*| raise Redis::BaseError, 'down' }
      client.define_singleton_method(:flushdb) { nil }
      store = ActiveSupport::Cache::RedisCacheStore.new(redis: client)
      allow(Rails).to receive(:cache).and_return(store)

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_sensitive).to be false
      end
      expect(seen.any? { |key| key.include?('/rev/') }).to be true
      expect(seen.none? { |key| key.include?(legacy) && !key.include?('/rev/') }).to be true
    ensure
      allow(Rails).to receive(:cache).and_call_original
    end

    it 'does not fall back to the legacy key when the cache raises' do
      legacy = Setting.cache_key('default_sensitive', user)
      Rails.cache.write(legacy, true)
      fetched = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |_method, key, *_args, &_block|
        fetched << key
        raise ConnectionPool::TimeoutError, 'pool timeout' if key.include?('/rev/')
      end

      expect do
        UserPreferences::RevisionMemo.scope { user.setting_default_sensitive }
      end.to raise_error(ConnectionPool::TimeoutError)

      expect(fetched).not_to include(legacy)
    end

    it 'does not fall back to the legacy key when the revision select raises' do
      legacy = Setting.cache_key('default_sensitive', user)
      Rails.cache.write(legacy, true)
      allow(UserPreferences::Revision).to receive(:current).and_raise(ActiveRecord::StatementInvalid, 'db down')

      expect do
        UserPreferences::RevisionMemo.scope { user.setting_default_sensitive }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'writer in the same unit' do
    self.use_transactional_tests = false

    after { discard_user(@user) if @user }

    it 'moves the memo to the committed revision and ignores a late write to the old key' do
      @user = Fabricate(:user)
      user = @user
      UserPreferenceRevision.create!(user_id: user.id, revision: 6)
      user.settings['default_sensitive'] = false
      old_key = UserPreferences::CacheKey.for_revision('default_sensitive', user, 6)
      new_key = UserPreferences::CacheKey.for_revision('default_sensitive', user, 7)
      late_value = nil
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, key, *args, &block|
        if key == old_key && late_value.nil?
          late_value = block.call
          :paused
        else
          method.call(key, *args, &block)
        end
      end

      UserPreferences::RevisionMemo.scope { user.setting_default_sensitive }
      expect(late_value).to be false

      UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => true })
      Rails.cache.write(old_key, late_value)

      UserPreferences::RevisionMemo.scope do
        expect(user.setting_default_sensitive).to be true
      end
      expect(Rails.cache.read(old_key)).to be false
      expect(Rails.cache.read(new_key)).to be true
    end

    it 'updates the memo after commit even when cache deletion fails, and not on rollback or no-op' do
      @user = Fabricate(:user)
      user = @user
      other = Fabricate(:user)
      begin
        UserPreferences::RevisionMemo.scope do
          expect(UserPreferences::RevisionMemo.revision_for(user.id)).to eq 0
          expect(UserPreferences::RevisionMemo.revision_for(other.id)).to eq 0
          allow(Rails.cache).to receive(:delete).and_raise(StandardError, 'cache down')
          result = UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'unlisted' })
          expect(result.cache_deleted).to eq('default_privacy' => false)
          expect(UserPreferences::RevisionMemo.revision_for(user.id)).to eq 1
          expect(UserPreferences::RevisionMemo.revision_for(other.id)).to eq 0

          UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'unlisted' })
          expect(UserPreferences::RevisionMemo.revision_for(user.id)).to eq 1

          allow_any_instance_of(Setting).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'bad sql')
          expect do
            UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'private' })
          end.to raise_error(ActiveRecord::StatementInvalid)
          expect(UserPreferences::RevisionMemo.revision_for(user.id)).to eq 1
        end
      ensure
        discard_user(other)
      end
    end

    it 'remembers the committed revision after notification and not on a failed unique retry' do
      @user = Fabricate(:user)
      user = @user
      order = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
        order << :commit if payload[:sql].to_s.match?(/\A\s*COMMIT\b/i)
      end
      allow(Rails.cache).to receive(:delete).and_wrap_original do |method, key, *args|
        order << :delete if key.to_s.include?('/rev/')
        method.call(key, *args)
      end
      allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
        method.call do |redis|
          block.call(RecordingPublisher.new(redis, [], [], lambda { order << :notify }))
        end
      end
      allow(UserPreferences::RevisionMemo).to receive(:remember!).and_wrap_original do |method, *args|
        order << :memo
        method.call(*args)
      end
      attempts = 0
      allow(UserPreferenceRevision).to receive(:create!).and_wrap_original do |method, *args|
        attempts += 1
        raise ActiveRecord::RecordNotUnique, 'retry' if attempts == 1

        method.call(*args)
      end

      UserPreferences::RevisionMemo.scope do
        UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
        expect(UserPreferences::RevisionMemo.revision_for(user.id)).to eq 1
      end

      expect(order).to eq(%i(commit delete notify memo))
      expect(attempts).to eq 2
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'selects each missed setting once after one revision select' do
      @user = Fabricate(:user)
      user = @user
      UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => true })

      selects = sql_log do
        UserPreferences::RevisionMemo.scope do
          user.setting_default_privacy
          user.setting_default_sensitive
          user.setting_default_language
          user.setting_show_translation_bar
          user.setting_translation_preferred_mode
          user.setting_new_features_policy
          user.setting_content_font_size
          user.setting_info_font_size
          user.setting_reduce_motion
        end
      end

      expect(revision_selects(selects).size).to eq 1
      expect(settings_selects(selects).size).to eq 9
    end
  end
end
