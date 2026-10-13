# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::LegacyWriter do
  self.use_transactional_tests = false

  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def revision(user)
    UserPreferences::Revision.current(user.id)
  end

  def reader(user, key)
    UserPreferences::Reader.new(user).get(key)
  end

  def errors_for
    yield
    []
  rescue UserPreferences::InvalidInput => error
    error.errors
  end

  describe 'checked legacy input' do
    let(:user) { Fabricate(:user) }
    let(:writer) { described_class.new(user) }

    after { discard_user(user) }

    it 'accepts only the nine stored keys and does not publish an unchecked writer entry' do
      expect(described_class::KEYS).to eq(UserPreferences::WriteContract::KEYS)
      expect(described_class::KEYS).not_to include('preferred_posting_language', 'noindex')
      expect(UserPreferences::Writer.public_instance_methods(false)).to contain_exactly(:apply)
      expect(File.read(Rails.root.join('app/controllers/settings/preferences_controller.rb'))).not_to include('LegacyWriter')
      expect(File.read(Rails.root.join('app/controllers/api/v1/accounts/credentials_controller.rb'))).not_to include('LegacyWriter')
      expect(File.read(Rails.root.join('app/lib/user_settings_decorator.rb'))).not_to include('LegacyWriter')
    end

    it 'rejects unknown keys, derived keys, high-risk keys, and non-scalars' do
      expect(errors_for { writer.update('noindex', '1') }).to include('key' => 'noindex', 'code' => 'unknown_key')
      expect(errors_for { writer.update('preferred_posting_language', 'ja') }).to include('key' => 'preferred_posting_language', 'code' => 'unknown_key')
      expect(errors_for { writer.update(:default_privacy, 'direct') }).to include('key' => nil, 'code' => 'invalid_key')
      expect(errors_for { writer.update('default_privacy', { 'bad' => 'direct' }) }).to include('key' => 'default_privacy', 'code' => 'invalid_type')
      expect(errors_for { writer.update('default_language', ['ja-JP']) }).to include('key' => 'default_language', 'code' => 'invalid_type')
      expect(errors_for { writer.update('content_font_size', ActionController::Parameters.new('bad' => '18')) }).to include('key' => 'content_font_size', 'code' => 'invalid_type')
      expect(errors_for { writer.update('content_font_size', 18) }).to include('key' => 'content_font_size', 'code' => 'invalid_type')
      expect(stored(user, 'default_privacy')).to be_nil
      expect(stored(user, 'noindex')).to be_nil
      expect(revision(user)).to eq 0
    end

    it 'keeps public apply on the strict contract' do
      public_writer = UserPreferences::Writer.new(user)

      expect { public_writer.apply(updates: { 'default_privacy' => 'direct' }) }.to raise_error(UserPreferences::InvalidInput)
      expect { public_writer.apply(updates: { 'default_language' => 'ja-JP' }) }.to raise_error(UserPreferences::InvalidInput)
      expect { public_writer.apply(updates: { 'content_font_size' => '18' }) }.to raise_error(UserPreferences::InvalidInput)
      expect { public_writer.apply(updates: { 'default_sensitive' => nil }) }.to raise_error(UserPreferences::InvalidInput)
      expect { public_writer.apply(updates: { 'reduce_motion' => '' }) }.to raise_error(UserPreferences::InvalidInput)

      expect(stored(user, 'default_privacy')).to be_nil
      expect(revision(user)).to eq 0
    end

    it 'stores direct, an empty privacy string, a regional language, a policy string, and font-size strings' do
      writer.update('default_privacy', 'direct')
      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(reader(user, 'default_privacy')).to have_attributes(state: :present, configured: 'direct')

      writer.update('default_privacy', '')
      expect(stored(user, 'default_privacy').value).to eq ''
      expect(reader(user, 'default_privacy').configured).to eq ''

      writer.update('default_language', 'ja-JP')
      expect(stored(user, 'default_language').value).to eq 'ja-JP'
      expect(reader(user, 'default_language').configured).to eq 'ja-JP'
      expect(stored(user, 'preferred_posting_language')).to be_nil

      writer.update('new_features_policy', 'nope')
      expect(stored(user, 'new_features_policy').value).to eq 'nope'

      writer.update('content_font_size', '18')
      writer.update('info_font_size', '16')
      expect(stored(user, 'content_font_size').value).to eq '18'
      expect(stored(user, 'content_font_size').value).to be_a(String)
      expect(stored(user, 'info_font_size').value).to eq '16'
      expect(reader(user, 'content_font_size').configured).to eq '18'
      expect(revision(user)).to eq 6
    end

    it 'casts boolean strings and stores an empty boolean string as a nil row' do
      sensitive = writer.update('default_sensitive', '0')
      motion = writer.update('reduce_motion', '1')

      expect(sensitive.after['default_sensitive']).to eq(state: :present, configured: false)
      expect(stored(user, 'default_sensitive').value).to be false
      expect(motion.after['reduce_motion']).to eq(state: :present, configured: true)
      expect(stored(user, 'reduce_motion').value).to be true

      cleared = writer.update('default_sensitive', '')

      expect(stored(user, 'default_sensitive')).to be_present
      expect(stored(user, 'default_sensitive').value).to be_nil
      expect(reader(user, 'default_sensitive')).to have_attributes(state: :nil, configured: nil)
      expect(cleared.after['default_sensitive']).to eq(state: :nil, configured: nil)
      expect(cleared.before['default_sensitive']).to eq(state: :present, configured: false)
      expect(cleared.changed_keys).to eq ['default_sensitive']
      expect(reader(user, 'default_sensitive').state).not_to eq :absent
      expect(revision(user)).to eq 3
    end

    it 'skips an actual nil without writing, and treats a repeated nil row as a no-op' do
      user.settings['default_privacy'] = 'unlisted'
      row = stored(user, 'default_privacy')
      row.update_columns(updated_at: 3.hours.ago)
      stamp = row.reload.updated_at

      skipped = writer.update('default_privacy', nil)

      expect(skipped.changed_keys).to eq []
      expect(skipped.before_revision).to eq skipped.after_revision
      expect(row.reload.value).to eq 'unlisted'
      expect(row.updated_at).to eq stamp
      expect(revision(user)).to eq 0

      created = writer.update('reduce_motion', '')
      expect(created.after['reduce_motion']).to eq(state: :nil, configured: nil)
      expect(reader(user, 'reduce_motion').state).to eq :nil
      created_revision = revision(user)

      repeated = writer.update('reduce_motion', '')

      expect(repeated.changed_keys).to eq []
      expect(repeated.unchanged_keys).to eq ['reduce_motion']
      expect(repeated.after['reduce_motion']).to eq(state: :nil, configured: nil)
      expect(repeated.before_revision).to eq created_revision
      expect(repeated.after_revision).to eq created_revision
      expect(stored(user, 'reduce_motion').value).to be_nil
    end

    it 'normalizes translation mode and uses the policy captured before later writes' do
      user.settings['new_features_policy'] = 'default'
      snapshot = user.setting_new_features_policy
      legacy = described_class.new(user, policy: snapshot)

      legacy.update('new_features_policy', 'conservative')
      bar = legacy.update('show_translation_bar', 'nope')
      mode = legacy.update('translation_preferred_mode', 'original')

      expect(snapshot).to eq 'default'
      expect(bar.after['show_translation_bar']).to eq(state: :present, configured: 'target')
      expect(stored(user, 'show_translation_bar').value).to eq 'target'
      expect(stored(user, 'new_features_policy').value).to eq 'conservative'
      expect(mode.after['translation_preferred_mode']).to eq(state: :present, configured: 'translated')
      expect(stored(user, 'translation_preferred_mode').value).to eq 'translated'

      described_class.new(user).update('show_translation_bar', 'nope')
      expect(stored(user, 'show_translation_bar').value).to eq 'never'
    end

    it 'gives each changed key its own revision and leaves the earlier key when a later save fails' do
      writer.update('default_privacy', 'direct')
      expect(revision(user)).to eq 1

      allow_any_instance_of(Setting).to receive(:save!).and_raise('save failed')

      expect { writer.update('default_language', 'ja-JP') }.to raise_error(RuntimeError, 'save failed')

      expect(stored(user, 'default_privacy').value).to eq 'direct'
      expect(stored(user, 'default_language')).to be_nil
      expect(revision(user)).to eq 1
    end

    it 'refuses an open transaction before writing' do
      expect do
        User.transaction do
          writer.update('default_privacy', 'direct')
        end
      end.to raise_error(UserPreferences::OpenTransaction)

      expect(stored(user, 'default_privacy')).to be_nil
      expect(revision(user)).to eq 0
    end
  end

  describe 'real commit' do
    let(:user) { Fabricate(:user) }

    after { discard_user(user) }

    def legacy_key(var)
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

    it 'writes, deletes, and notifies after SQL commit, in that order' do
      key = legacy_key('default_privacy')
      events = nil
      messages = nil

      observe do |seen, published|
        described_class.new(user).update('default_privacy', 'direct')
        events = seen
        messages = published
      end

      relevant = events.select { |event| event[:op] == 'commit' || event[:key] == key || event[:op] == 'notify' }
      expect(relevant.map { |event| event[:op] }).to eq(%w(commit write delete notify)), events.inspect
      expect(relevant[1]).to include(source: 'rewrite_cache', value: 'direct', after_sql_commit: true)
      expect(relevant[2]).to include(source: 'cache_deletion', after_sql_commit: true)
      expect(relevant[3]).to include(after_sql_commit: true)
      expect(Rails.cache.exist?(key)).to be false
      expect(reader(user, 'default_privacy').configured).to eq 'direct'
      payload = JSON.parse(messages.fetch(0).last)
      expect(payload.dig('payload', 'changed_keys')).to eq ['user.default_privacy']
      expect(payload.dig('payload', 'revision')).to eq '1'
    end

    it 'does not save or notify a same-value resubmit' do
      described_class.new(user).update('default_privacy', 'direct')
      key = legacy_key('default_privacy')
      Rails.cache.write(key, 'sentinel')
      row = stored(user, 'default_privacy')
      row.update_columns(updated_at: 3.hours.ago)
      stamp = row.reload.updated_at

      events = nil
      messages = nil
      result = nil
      observe do |seen, published|
        result = described_class.new(user).update('default_privacy', 'direct')
        events = seen
        messages = published
      end

      expect(result.changed_keys).to eq []
      expect(result.unchanged_keys).to eq ['default_privacy']
      expect(result.cache_deleted).to eq({})
      expect(result.after_revision).to eq 1
      expect(events.map { |event| event[:op] }).to eq(%w(commit)), events.inspect
      expect(Rails.cache.read(key)).to eq 'sentinel'
      expect(row.reload.updated_at).to eq stamp
      expect(messages).to eq []
    end

    it 'notifies when a stored boolean becomes a nil row' do
      described_class.new(user).update('default_sensitive', true)
      messages = nil

      observe do |_seen, published|
        result = described_class.new(user).update('default_sensitive', '')
        expect(result.after['default_sensitive']).to eq(state: :nil, configured: nil)
        expect(result.after_revision).to eq 2
        messages = published
      end

      expect(stored(user, 'default_sensitive').value).to be_nil
      expect(reader(user, 'default_sensitive').state).to eq :nil
      payload = JSON.parse(messages.fetch(0).last)
      expect(payload.dig('payload', 'changed_keys')).to eq ['user.default_sensitive']
      expect(payload.dig('payload', 'revision')).to eq '2'
    end
  end

  describe 'user row lock' do
    let(:user) { Fabricate(:user) }

    after { discard_user(user) }

    it 'waits behind another writer that holds the same user row' do
      release = Queue.new
      state = { locked: false, started: false, finished: false }
      first = UserPreferences::Writer.new(user)
      allow(first).to receive(:lock_user).and_wrap_original do |method|
        locked = method.call
        state[:locked] = true
        release.pop
        locked
      end
      first_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          first.apply(updates: { 'default_sensitive' => true })
        end
      end
      deadline = Time.now + 5
      sleep 0.05 until state[:locked] || Time.now > deadline
      expect(state[:locked]).to be true

      second_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          state[:started] = true
          described_class.new(user).update('reduce_motion', '1')
          state[:finished] = true
        end
      end
      sleep 0.05 until state[:started] || Time.now > deadline
      sleep 0.2
      expect(state[:finished]).to be false

      release << true
      first_thread.join
      second_thread.join

      expect(stored(user, 'default_sensitive').value).to be true
      expect(stored(user, 'reduce_motion').value).to be true
      expect(revision(user)).to eq 2
    end
  end
end
