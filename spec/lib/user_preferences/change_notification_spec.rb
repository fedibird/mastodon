# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::ChangeNotification do
  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    Doorkeeper::AccessToken.where(resource_owner_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def install_recorder
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |redis|
        block.call(RecordingPublisher.new(redis, @messages, @returns, @observer))
      end
    end
  end

  def install_raising_publisher
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |redis|
        block.call(RaisingPublisher.new(redis, @messages))
      end
    end
  end

  def install_zero_publisher
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |_redis|
        block.call(ZeroPublisher.new(@messages, @returns))
      end
    end
  end

  def event_at(index)
    JSON.parse(@messages.fetch(index).last)
  end

  def preference_channels
    @messages.map(&:first)
  end

  def observe_other_connection(user, key)
    seen = { transaction_open: User.connection.transaction_open? }
    other = ActiveRecord::Base.connection_pool.checkout
    begin
      seen[:raw_value] = other.select_value(<<~SQL.squish)
        SELECT value FROM settings
        WHERE thing_type = 'User' AND thing_id = #{user.id.to_i} AND var = #{other.quote(key)}
      SQL
      seen[:revision] = other.select_value(<<~SQL.squish)
        SELECT revision FROM user_preference_revisions
        WHERE user_id = #{user.id.to_i}
      SQL
    ensure
      ActiveRecord::Base.connection_pool.checkin(other)
    end
    seen
  end

  describe 'callback contract' do
    self.use_transactional_tests = false

    before do
      @messages = []
      @returns = []
      @errors = []
      @observer = nil
      install_recorder
      allow(Rails.logger).to receive(:error).and_wrap_original do |method, *args|
        @errors << args.first
        method.call(*args)
      end
    end

    let(:notification) do
      described_class.new(
        user_id: 10,
        account_id: 99,
        changed_keys: ['default_language', 'reduce_motion', 'default_language', 'email'],
        revision: 9_223_372_036_854_775_807
      )
    end

    it 'uses the account id in the channel and keeps public keys in order' do
      expect(notification.user_id).to eq 10
      expect(notification.account_id).to eq 99
      expect(notification.channel).to eq 'timeline:preferences:99'
      expect(notification.channel).not_to eq 'timeline:99'
      expect(notification.channel).not_to eq 'timeline:preferences:10'
      expect(notification.changed_keys).to eq %w(user.default_language user.reduce_motion)
      expect(notification.revision).to eq '9223372036854775807'
      expect(notification.trigger_transactional_callbacks?).to be true
    end

    it 'does not publish from before_committed! or committed!(should_run_callbacks: false)' do
      notification.before_committed!
      notification.committed!(should_run_callbacks: false)

      expect(@messages).to be_empty
    end

    it 'does not publish from rolledback! even if committed! is called afterwards' do
      notification.rolledback!(force_restore_state: true, should_run_callbacks: true)
      notification.committed!(should_run_callbacks: true)

      expect(@messages).to be_empty
    end

    it 'publishes one decimal revision string and no stored values' do
      notification.committed!(should_run_callbacks: true)
      parsed = event_at(0)

      expect(preference_channels).to eq ['timeline:preferences:99']
      expect(parsed.keys).to match_array(%w(event payload queued_at))
      expect(parsed['event']).to eq 'preferences_changed'
      expect(parsed['queued_at']).to be_a(Integer)
      expect(parsed['payload']).to eq(
        'version' => 1,
        'revision' => '9223372036854775807',
        'changed_keys' => %w(user.default_language user.reduce_motion)
      )
      expect(parsed['payload']['revision']).to be_a(String)
      raw = @messages.first.last
      expect(raw).not_to include('configured')
      expect(raw).not_to include('effective')
      expect(raw).not_to include('public_value')
      expect(raw).not_to include('email')
    end

    it 'publishes nothing when every key is empty or unknown' do
      empty = described_class.new(user_id: 10, account_id: 99, changed_keys: [], revision: 1)
      unknown = described_class.new(user_id: 10, account_id: 99, changed_keys: ['email'], revision: 1)

      empty.committed!(should_run_callbacks: true)
      unknown.committed!(should_run_callbacks: true)

      expect(@messages).to be_empty
    end
  end

  describe 'commits' do
    self.use_transactional_tests = false

    let(:user) { Fabricate(:user, email: 'pref-notify-secret@example.test', locale: 'ja') }

    before do
      @messages = []
      @returns = []
      @errors = []
      @observer = nil
      @seen = nil
      install_recorder
      allow(Rails.logger).to receive(:error).and_wrap_original do |method, *args|
        @errors << args.first
        method.call(*args)
      end
    end

    after { discard_user(user) }

    it 'publishes one insert event after the committed value and revision are visible' do
      expect(user.id).not_to eq user.account_id
      @observer = lambda do
        @seen = observe_other_connection(user, 'default_sensitive')
      end

      result = UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => false })
      parsed = event_at(0)
      loaded = @seen[:raw_value].is_a?(String) ? YAML.unsafe_load(@seen[:raw_value]) : @seen[:raw_value]

      expect(@messages.size).to eq 1
      expect(preference_channels).to eq ["timeline:preferences:#{user.account_id}"]
      expect(preference_channels).not_to include("timeline:#{user.account_id}")
      expect(@returns).to eq [0]
      expect(@seen[:transaction_open]).to be false
      expect(loaded).to be false
      expect(@seen[:revision].to_i).to eq 1
      expect(result.after_revision).to eq 1
      expect(parsed['payload']).to eq(
        'version' => 1,
        'revision' => '1',
        'changed_keys' => ['user.default_sensitive']
      )
      expect(@errors.join).not_to include('change notification failed')
    end

    it 'publishes one event for several keys and keeps the change set order' do
      result = UserPreferences::Writer.new(user).apply(
        updates: {
          'show_translation_bar' => 'never',
          'default_language' => 'zh-TW',
          'reduce_motion' => true,
        }
      )

      expect(@messages.size).to eq 1
      expect(result.changed_keys).to eq %w(show_translation_bar default_language reduce_motion)
      expect(result.after_revision).to eq 1
      expect(event_at(0)['payload']).to eq(
        'version' => 1,
        'revision' => '1',
        'changed_keys' => %w(user.show_translation_bar user.default_language user.reduce_motion)
      )
    end

    it 'publishes one event for a reset and none for an absent reset' do
      UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'de', 'reduce_motion' => true })
      @messages.clear

      deleted = UserPreferences::Writer.new(user).apply(resets: ['reduce_motion', 'default_language'])
      absent = UserPreferences::Writer.new(user).apply(resets: ['default_language'])

      expect(@messages.size).to eq 1
      expect(deleted.after_revision).to eq 2
      expect(event_at(0)['payload']).to eq(
        'version' => 1,
        'revision' => '2',
        'changed_keys' => %w(user.reduce_motion user.default_language)
      )
      expect(absent.changed_keys).to eq []
      expect(absent.after_revision).to eq 2
      expect(stored(user, 'default_language')).to be_nil
    end

    it 'publishes the next decimal revision and a large bigint as a string' do
      first = UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => false })
      second = UserPreferences::Writer.new(user).apply(updates: { 'reduce_motion' => true })

      expect(event_at(0).dig('payload', 'revision')).to eq '1'
      expect(event_at(1).dig('payload', 'revision')).to eq '2'
      expect(first.after_revision).to eq 1
      expect(second.after_revision).to eq 2

      UserPreferenceRevision.find_by!(user_id: user.id).update!(revision: 9_223_372_036_854_775_806)
      @messages.clear
      large = UserPreferences::Writer.new(user).apply(updates: { 'content_font_size' => 17 })

      expect(large.after_revision).to eq 9_223_372_036_854_775_807
      expect(event_at(0).dig('payload', 'revision')).to eq '9223372036854775807'
      expect(event_at(0).dig('payload', 'revision')).to be_a(String)
    end

    it 'does not publish a no-op, an empty apply, or an invalid value' do
      UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'zh-TW' })
      @messages.clear

      same = UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'zh-TW' })
      empty = UserPreferences::Writer.new(user).apply
      blank = UserPreferences::Writer.new(user).apply(updates: {}, resets: [])

      expect(same.after_revision).to eq 1
      expect(empty.after_revision).to eq 1
      expect(blank.after_revision).to eq 1
      expect do
        UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'ja-JP' })
      end.to raise_error(UserPreferences::InvalidInput)

      expect(@messages).to be_empty
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
    end

    it 'does not publish when a later save rolls back' do
      writer = UserPreferences::Writer.new(user)
      allow(writer).to receive(:insert_row).and_wrap_original do |method, user_id, key, value|
        raise 'second key failed' if key == 'reduce_motion'

        method.call(user_id, key, value)
      end

      expect do
        writer.apply(updates: { 'default_sensitive' => true, 'reduce_motion' => true })
      end.to raise_error(RuntimeError, 'second key failed')

      expect(@messages).to be_empty
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id)).to be_empty
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
    end

    it 'does not publish a rolled-back transaction record' do
      notification = described_class.new(
        user_id: user.id,
        account_id: user.account_id,
        changed_keys: ['reduce_motion'],
        revision: 1
      )

      User.transaction do
        User.connection.add_transaction_record(notification)
        raise ActiveRecord::Rollback
      end

      expect(@messages).to be_empty
    end

    it 'does not publish while a transaction is open' do
      notification = described_class.new(
        user_id: user.id,
        account_id: user.account_id,
        changed_keys: ['reduce_motion'],
        revision: 1
      )

      User.transaction do
        notification.committed!(should_run_callbacks: true)
        raise ActiveRecord::Rollback
      end

      expect(@messages).to be_empty
      expect(@errors.join).to include("user_id=#{user.id}")
      expect(@errors.join).to include("account_id=#{user.account_id}")
      expect(@errors.join).to include('error=open_transaction')
    end

    it 'does not publish the failed RecordNotUnique attempts' do
      writer = UserPreferences::Writer.new(user)
      allow(writer).to receive(:insert_row).and_wrap_original do |method, user_id, key, value|
        raise ActiveRecord::RecordNotUnique, 'duplicate key' if key == 'reduce_motion'

        method.call(user_id, key, value)
      end

      expect do
        writer.apply(updates: { 'default_sensitive' => true, 'reduce_motion' => true })
      end.to raise_error(UserPreferences::Conflict)

      expect(@messages).to be_empty
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id)).to be_empty
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
    end

    it 'publishes only the attempt that commits after a unique violation' do
      writer = UserPreferences::Writer.new(user)
      raced = false
      allow(writer).to receive(:insert_row).and_wrap_original do |method, user_id, key, value|
        unless raced
          raced = true
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              record = Setting.unscoped.new(thing_type: 'User', thing_id: user_id, var: key)
              record.value = false
              record.save!
            end
          end.join
        end
        method.call(user_id, key, value)
      end

      result = writer.apply(updates: { 'default_sensitive' => true })

      expect(@messages.size).to eq 1
      expect(result.after_revision).to eq 1
      expect(event_at(0).dig('payload', 'revision')).to eq '1'
      expect(stored(user, 'default_sensitive').value).to be true
    end

    it 'keeps the committed write when redis publish fails' do
      install_raising_publisher

      result = UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'zh-TW' })

      expect(result.after_revision).to eq 1
      expect(result.cache_deleted).to eq('default_language' => true)
      expect(stored(user, 'default_language').value).to eq 'zh-TW'
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
      expect(@messages.size).to eq 1
      expect(@errors.join).to include("user_id=#{user.id}")
      expect(@errors.join).to include("account_id=#{user.account_id}")
      expect(@errors.join).to include('revision=1')
      expect(@errors.join).to include('error=Redis::CannotConnectError')
      expect(@errors.join).not_to include('zh-TW')
      expect(@errors.join).not_to include(user.email)
    end

    it 'still publishes when cache deletion fails' do
      allow(Rails.cache).to receive(:delete).and_raise(StandardError, 'cache unavailable')

      result = UserPreferences::Writer.new(user).apply(updates: { 'default_privacy' => 'private' })

      expect(result.cache_deleted).to eq('default_privacy' => false)
      expect(@messages.size).to eq 1
      expect(event_at(0).dig('payload', 'changed_keys')).to eq ['user.default_privacy']
      expect(stored(user, 'default_privacy').value).to eq 'private'
    end

    it 'treats a publish return of zero as success' do
      install_zero_publisher

      result = UserPreferences::Writer.new(user).apply(updates: { 'info_font_size' => 12 })

      expect(@returns).to eq [0]
      expect(result.after_revision).to eq 1
      expect(stored(user, 'info_font_size').value).to eq 12
      expect(@errors.join).not_to include('change notification failed')
    end

    it 'uses a different channel for each account and omits values and identity fields' do
      user.account.update_columns(username: 'secretprefuser')
      other = Fabricate(:user, email: 'other-pref-secret@example.test')
      other.account.update_columns(username: 'othersecretuser')

      UserPreferences::Writer.new(user).apply(updates: { 'default_language' => 'zh-TW' })
      UserPreferences::Writer.new(other).apply(updates: { 'reduce_motion' => true })

      expect(preference_channels).to eq [
        "timeline:preferences:#{user.account_id}",
        "timeline:preferences:#{other.account_id}",
      ]
      expect(user.account_id).not_to eq other.account_id
      expect(preference_channels).not_to include("timeline:#{user.account_id}")
      expect(preference_channels).not_to include("timeline:preferences:#{user.id}")
      raw = @messages.map(&:last).join
      %w(pref-notify-secret@example.test other-pref-secret@example.test secretprefuser othersecretuser zh-TW).each do |secret|
        expect(raw).not_to include(secret)
      end
      expect(raw).not_to include('configured')
      expect(raw).not_to include('effective')
      expect(raw).not_to include('public_value')
    ensure
      discard_user(other)
    end

    it 'delivers the committed event on the preferences channel' do
      channel = nil
      listener = nil
      channel = "timeline:preferences:#{user.account_id}"
      received = Queue.new
      ready = Queue.new
      listener = Thread.new do
        RedisConfiguration.with do |redis|
          redis.subscribe(channel) do |on|
            on.subscribe { ready << true }
            on.message do |_name, message|
              received << message
              redis.unsubscribe
            end
          end
        end
      rescue StandardError => error
        ready << error
      end
      ready_result = Timeout.timeout(5) { ready.pop }
      raise ready_result if ready_result.is_a?(Exception)

      UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => true })
      message = Timeout.timeout(5) { received.pop }
      parsed = JSON.parse(message)

      expect(preference_channels).to eq [channel]
      expect(parsed.dig('payload', 'revision')).to eq '1'
      expect(parsed.dig('payload', 'changed_keys')).to eq ['user.default_sensitive']
      expect(message).not_to include(user.email)
    ensure
      if listener&.alive? && channel
        RedisConfiguration.with { |redis| redis.publish(channel, '{"event":"release"}') }
        listener.join(3)
      end
    end
  end
end
