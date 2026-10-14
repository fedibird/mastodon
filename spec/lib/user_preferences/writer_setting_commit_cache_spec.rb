# frozen_string_literal: true

require 'rails_helper'

# Real COMMIT. rails-settings-cached 0.6.6 (86328ef0bd04) registers
# RailsSettings::Base.after_commit :rewrite_cache on create and update.
# Writer does not call Rails.cache.write itself. These examples separate that
# model callback from CacheDeletion, which runs only after SQL COMMIT.
RSpec.describe 'Writer setting commit cache' do
  self.use_transactional_tests = false

  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def legacy_key(user, var)
    Setting.cache_key(var, user)
  end

  def revision_key(user, var, revision)
    UserPreferences::CacheKey.for_revision(var, user, revision)
  end

  def cache_source(frames)
    return 'rewrite_cache' if frames.any? { |frame| frame.include?('rewrite_cache') }
    return 'expire_cache' if frames.any? { |frame| frame.include?('expire_cache') }
    return 'cache_deletion' if frames.any? { |frame| frame.include?('cache_deletion.rb') }
    return 'scoped_settings' if frames.any? { |frame| frame.include?('scoped_settings.rb') }

    'other'
  end

  def observe_cache
    events = []
    sql_committed = false
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if sql.include?('SCHEMA')

      kind = if sql.match?(/\A\s*COMMIT\b/i)
               sql_committed = true
               'commit'
             elsif sql.match?(/\A\s*RELEASE SAVEPOINT\b/i)
               'release_savepoint'
             elsif sql.match?(/\A\s*(BEGIN|SAVEPOINT)\b/i)
               'begin'
             end
      next unless kind

      events << {
        op: kind,
        after_sql_commit: sql_committed && kind != 'commit',
        transaction_open: Setting.connection.transaction_open?,
      }
    end
    allow(Rails.cache).to receive(:write).and_wrap_original do |method, key, value, *rest|
      if key.to_s.include?('rails_settings_cached')
        events << {
          op: 'write',
          key: key,
          value: value,
          source: cache_source(caller),
          after_sql_commit: sql_committed,
          transaction_open: Setting.connection.transaction_open?,
        }
      end
      method.call(key, value, *rest)
    end
    allow(Rails.cache).to receive(:delete).and_wrap_original do |method, key, *rest|
      if key.to_s.include?('rails_settings_cached')
        events << {
          op: 'delete',
          key: key,
          source: cache_source(caller),
          after_sql_commit: sql_committed,
          transaction_open: Setting.connection.transaction_open?,
        }
      end
      method.call(key, *rest)
    end
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |redis|
        block.call(RecordingPublisher.new(redis, [], [], lambda {
          events << { op: 'notify', after_sql_commit: sql_committed }
        }))
      end
    end

    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def events_for(events, key)
    events.select { |event| event[:op] == 'commit' || event[:key] == key }
  end

  it 'writes the legacy key from the model callback and then deletes it when creating a setting' do
    user = Fabricate(:user)
    key = legacy_key(user, 'reduce_motion')

    events = observe_cache do
      UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
    end

    rev = revision_key(user, 'reduce_motion', 1)
    relevant = events.select { |event| event[:op] == 'commit' || event[:op] == 'notify' || event[:key] == key || event[:key] == rev }
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit write delete delete notify)), events.inspect
    expect(relevant[1]).to include(source: 'rewrite_cache', value: true, after_sql_commit: true, transaction_open: false)
    expect(relevant[2]).to include(key: key, source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(relevant[3]).to include(key: rev, source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(relevant[1][:key]).to eq key
    expect(Rails.cache.exist?(key)).to be false
    expect(Rails.cache.exist?(rev)).to be false
    expect(Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'reduce_motion').value).to be true
    expect(UserPreferences::Reader.new(user).get('reduce_motion')).to have_attributes(state: :present, configured: true)
  ensure
    discard_user(user)
  end

  it 'writes the new value from the model callback and then deletes it when updating a setting' do
    user = Fabricate(:user)
    key = legacy_key(user, 'reduce_motion')
    UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => false })
    Rails.cache.write(key, 'stale')
    previous = revision_key(user, 'reduce_motion', 1)
    current = revision_key(user, 'reduce_motion', 2)
    Rails.cache.write(previous, 'old-generation')

    events = observe_cache do
      UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
    end

    relevant = events.select { |event| event[:op] == 'commit' || event[:key] == key || event[:key] == current || event[:key] == previous }
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit write delete delete)), events.inspect
    expect(relevant[1]).to include(source: 'rewrite_cache', value: true, after_sql_commit: true)
    expect(relevant[2]).to include(key: key, source: 'cache_deletion', after_sql_commit: true)
    expect(relevant[3]).to include(key: current, source: 'cache_deletion', after_sql_commit: true)
    expect(Rails.cache.exist?(key)).to be false
    expect(Rails.cache.exist?(current)).to be false
    expect(Rails.cache.read(previous)).to eq 'old-generation'
    expect(UserPreferences::Reader.new(user).get('reduce_motion')).to have_attributes(state: :present, configured: true)
  ensure
    discard_user(user)
  end

  it 'does not write or delete the legacy key for a same-value no-op' do
    user = Fabricate(:user)
    key = legacy_key(user, 'reduce_motion')
    UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
    row = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'reduce_motion')
    row.update_columns(updated_at: 3.hours.ago)
    stamp = row.reload.updated_at
    revision = UserPreferences::Revision.current(user.id)
    rev = revision_key(user, 'reduce_motion', revision)
    Rails.cache.write(key, 'sentinel')
    Rails.cache.write(rev, 'sentinel')

    events = observe_cache do
      result = UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
      expect(result.changed_keys).to eq []
      expect(result.unchanged_keys).to eq ['reduce_motion']
      expect(result.cache_deleted).to eq({})
    end

    expect(events_for(events, key).map { |event| event[:op] }).to eq(%w(commit)), events.inspect
    expect(events.none? { |event| event[:key] == rev }).to be true
    expect(Rails.cache.read(key)).to eq 'sentinel'
    expect(Rails.cache.read(rev)).to eq 'sentinel'
    expect(row.reload.updated_at).to eq stamp
    expect(UserPreferences::Revision.current(user.id)).to eq revision
    expect(UserPreferences::Reader.new(user).get('reduce_motion')).to have_attributes(state: :present, configured: true)
  ensure
    discard_user(user)
  end

  it 'deletes the legacy key after commit on reset and does not run the model cache callbacks' do
    user = Fabricate(:user)
    key = legacy_key(user, 'reduce_motion')
    UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
    Rails.cache.write(key, 'sentinel')

    events = observe_cache do
      result = UserPreferences::Writer.new(user).apply(resets: ['reduce_motion'])
      expect(result.changed_keys).to eq ['reduce_motion']
      expect(result.cache_deleted).to eq('reduce_motion' => true)
    end

    rev = revision_key(user, 'reduce_motion', 2)
    relevant = events.select { |event| event[:op] == 'commit' || event[:op] == 'notify' || event[:key] == key || event[:key] == rev }
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit delete delete notify)), events.inspect
    expect(relevant[1]).to include(key: key, source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(relevant[2]).to include(key: rev, source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(events.select { |event| event[:key] == key && %w(rewrite_cache expire_cache).include?(event[:source]) }).to be_empty
    expect(Rails.cache.exist?(key)).to be false
    expect(Rails.cache.exist?(rev)).to be false
    expect(Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'reduce_motion')).to be_nil
    expect(UserPreferences::Reader.new(user).get('reduce_motion').state).to eq :absent
  ensure
    discard_user(user)
  end

  it 'deletes both changed keys at the same after revision and leaves the other key' do
    user = Fabricate(:user)
    privacy = legacy_key(user, 'default_privacy')
    sensitive = legacy_key(user, 'default_sensitive')
    language = legacy_key(user, 'default_language')
    Rails.cache.write(language, 'leave-me')
    Rails.cache.write(revision_key(user, 'default_language', 1), 'leave-me')

    described_class_writer = UserPreferences::Writer.new(user)
    described_class_writer.apply(updates: { 'default_privacy' => 'unlisted', 'default_sensitive' => true })

    expect(Rails.cache.exist?(privacy)).to be false
    expect(Rails.cache.exist?(sensitive)).to be false
    expect(Rails.cache.exist?(revision_key(user, 'default_privacy', 1))).to be false
    expect(Rails.cache.exist?(revision_key(user, 'default_sensitive', 1))).to be false
    expect(Rails.cache.read(language)).to eq 'leave-me'
    expect(Rails.cache.read(revision_key(user, 'default_language', 1))).to eq 'leave-me'
    expect(UserPreferences::Revision.current(user.id)).to eq 1
  ensure
    discard_user(user)
  end

  it 'deletes neither cache generation when the setting save rolls back' do
    user = Fabricate(:user)
    key = legacy_key(user, 'default_privacy')
    rev = revision_key(user, 'default_privacy', 1)
    Rails.cache.write(key, 'sentinel')
    Rails.cache.write(rev, 'sentinel')
    allow_any_instance_of(Setting).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'bad sql')

    expect do
      UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'private' })
    end.to raise_error(ActiveRecord::StatementInvalid)

    expect(Rails.cache.read(key)).to eq 'sentinel'
    expect(Rails.cache.read(rev)).to eq 'sentinel'
    expect(UserPreferences::Revision.current(user.id)).to eq 0
    expect(Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'default_privacy')).to be_nil
  ensure
    discard_user(user)
  end

  it 'keeps trying the revision key when the legacy delete raises' do
    user = Fabricate(:user)
    key = legacy_key(user, 'default_privacy')
    rev = revision_key(user, 'default_privacy', 1)
    errors = []
    allow(Rails.logger).to receive(:error) { |line| errors << line }
    allow(Rails.cache).to receive(:delete).and_wrap_original do |method, cache_key, *rest|
      raise StandardError, 'legacy down' if cache_key == key

      method.call(cache_key, *rest)
    end

    result = UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'private' })

    expect(result.cache_deleted).to eq('default_privacy' => false)
    expect(Rails.cache.exist?(rev)).to be false
    expect(stored_revision(user)).to eq 1
    expect(errors.join).to include('generation=legacy')
    expect(errors.join).not_to include('generation=revision')
    expect(errors.join).not_to include('private')
  ensure
    discard_user(user)
  end

  it 'keeps trying later keys when one revision delete raises' do
    user = Fabricate(:user)
    privacy_rev = revision_key(user, 'default_privacy', 1)
    sensitive = legacy_key(user, 'default_sensitive')
    sensitive_rev = revision_key(user, 'default_sensitive', 1)
    allow(Rails.cache).to receive(:delete).and_wrap_original do |method, cache_key, *rest|
      raise StandardError, 'revision down' if cache_key == privacy_rev

      method.call(cache_key, *rest)
    end

    result = UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'unlisted', 'default_sensitive' => true })

    expect(result.cache_deleted).to eq('default_privacy' => true, 'default_sensitive' => true)
    expect(Rails.cache.exist?(sensitive)).to be false
    expect(Rails.cache.exist?(sensitive_rev)).to be false
    expect(stored_revision(user)).to eq 1
  ensure
    discard_user(user)
  end

  it 'does not confirm a deletion when Rails.cache.delete returns false' do
    user = Fabricate(:user)
    errors = []
    allow(Rails.logger).to receive(:error) { |line| errors << line }
    allow(Rails.cache).to receive(:delete).and_return(false)

    result = UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })

    expect(result.cache_deleted).to eq('reduce_motion' => false)
    expect(stored_revision(user)).to eq 1
    expect(Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'reduce_motion').value).to be true
    expect(errors.join).not_to include('cache delete failed')
  ensure
    discard_user(user)
  end

  def stored_revision(user)
    UserPreferences::Revision.current(user.id)
  end
end
