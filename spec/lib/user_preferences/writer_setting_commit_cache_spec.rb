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

    relevant = events_for(events, key)
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit write delete)), events.inspect
    expect(relevant[1]).to include(source: 'rewrite_cache', value: true, after_sql_commit: true, transaction_open: false)
    expect(relevant[2]).to include(source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(relevant[1][:key]).to eq key
    expect(relevant[2][:key]).to eq key
    expect(Rails.cache.exist?(key)).to be false
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

    events = observe_cache do
      UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
    end

    relevant = events_for(events, key)
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit write delete)), events.inspect
    expect(relevant[1]).to include(source: 'rewrite_cache', value: true, after_sql_commit: true)
    expect(relevant[2]).to include(source: 'cache_deletion', after_sql_commit: true)
    expect(Rails.cache.exist?(key)).to be false
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
    Rails.cache.write(key, 'sentinel')

    events = observe_cache do
      result = UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })
      expect(result.changed_keys).to eq []
      expect(result.unchanged_keys).to eq ['reduce_motion']
      expect(result.cache_deleted).to eq({})
    end

    expect(events_for(events, key).map { |event| event[:op] }).to eq(%w(commit)), events.inspect
    expect(Rails.cache.read(key)).to eq 'sentinel'
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

    relevant = events_for(events, key)
    expect(relevant.map { |event| event[:op] }).to eq(%w(commit delete)), events.inspect
    expect(relevant[1]).to include(source: 'cache_deletion', after_sql_commit: true, transaction_open: false)
    expect(events.select { |event| event[:key] == key && %w(rewrite_cache expire_cache).include?(event[:source]) }).to be_empty
    expect(Rails.cache.exist?(key)).to be false
    expect(Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'reduce_motion')).to be_nil
    expect(UserPreferences::Reader.new(user).get('reduce_motion').state).to eq :absent
  ensure
    discard_user(user)
  end
end
