# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::Writer do
  def discard_user(user)
    return unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  describe 'input and transaction guards' do
    self.use_transactional_tests = false

    it 'rejects an open joinable transaction before locking or writing' do
      user = Fabricate(:user)
      writer = described_class.new(user)
      expect(user).not_to receive(:lock!)

      User.transaction do
        expect { writer.apply(updates: { 'default_sensitive' => false, 'default_language' => 'ja-JP' }) }
          .to raise_error(UserPreferences::OpenTransaction)
      end

      expect(stored(user, 'default_sensitive')).to be_nil
    ensure
      discard_user(user)
    end

    it 'rejects an open non-joinable transaction before locking or writing' do
      user = Fabricate(:user)
      writer = described_class.new(user)

      User.transaction(joinable: false) do
        expect { writer.apply(updates: { 'reduce_motion' => true }) }
          .to raise_error(UserPreferences::OpenTransaction)
      end

      expect(stored(user, 'reduce_motion')).to be_nil
    ensure
      discard_user(user)
    end

    it 'writes nothing when one key in the batch is invalid' do
      user = Fabricate(:user)

      expect do
        described_class.new(user).apply(updates: { 'default_sensitive' => false, 'default_language' => 'ja-JP' })
      end.to raise_error(UserPreferences::InvalidInput)

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id)).to be_empty
    ensure
      discard_user(user)
    end

    it 'does not save unsaved changes on the caller user object' do
      user = Fabricate(:user)
      user.email = 'not-saved@example.com'

      described_class.new(user).apply(updates: { 'default_sensitive' => false })

      expect(user.email).to eq 'not-saved@example.com'
      expect(User.find(user.id).email).not_to eq 'not-saved@example.com'
    ensure
      discard_user(user)
    end
  end

  describe 'commits' do
    self.use_transactional_tests = false

    let(:user) { Fabricate(:user, locale: 'ja') }

    after { discard_user(user) }

    it 'inserts an explicit default for an absent key and keeps the other columns' do
      described_class.new(user).apply(updates: { 'default_sensitive' => false, 'reduce_motion' => false })
      sensitive = stored(user, 'default_sensitive')
      motion = stored(user, 'reduce_motion')

      expect(sensitive.value).to be false
      expect(motion.value).to be false
      expect(UserPreferences::Reader.new(user).get('default_sensitive').state).to eq :present
    end

    it 'inserts the yaml default policy when it was absent' do
      result = described_class.new(user).apply(updates: { 'new_features_policy' => 'default' })

      expect(result.before['new_features_policy']).to eq(state: :absent, configured: nil)
      expect(result.after['new_features_policy']).to eq(state: :present, configured: 'default')
      expect(result.changed_keys).to eq ['new_features_policy']
      expect(result.unchanged_keys).to eq []
      expect(stored(user, 'new_features_policy').value).to eq 'default'
    end

    it 'updates a present value, a nil row, and a stored false' do
      described_class.new(user).apply(updates: { 'default_privacy' => 'public', 'default_sensitive' => false })
      nil_row = Setting.unscoped.new(thing_type: 'User', thing_id: user.id, var: 'show_translation_bar')
      nil_row.value = nil
      nil_row.save!

      result = described_class.new(user).apply(
        updates: {
          'default_privacy' => 'unlisted',
          'default_sensitive' => true,
          'show_translation_bar' => 'never',
        }
      )

      expect(result.before['default_privacy']).to eq(state: :present, configured: 'public')
      expect(result.before['show_translation_bar'][:state]).to eq :nil
      expect(result.after['default_privacy'][:configured]).to eq 'unlisted'
      expect(result.after['default_sensitive'][:configured]).to be true
      expect(result.after['show_translation_bar']).to eq(state: :present, configured: 'never')
      expect(result.changed_keys).to eq %w(default_privacy default_sensitive show_translation_bar)
      expect(stored(user, 'default_sensitive').value).to be true
    end

    it 'deletes a stored row on reset and leaves an absent reset unchanged' do
      described_class.new(user).apply(updates: { 'default_language' => 'de' })

      deleted = described_class.new(user).apply(resets: ['default_language'])
      absent = described_class.new(user).apply(resets: ['default_language'])

      expect(deleted.changed_keys).to eq ['default_language']
      expect(deleted.after['default_language']).to eq(state: :absent, configured: nil)
      expect(stored(user, 'default_language')).to be_nil
      expect(absent.unchanged_keys).to eq ['default_language']
      expect(absent.changed_keys).to eq []
      expect(absent.cache_deleted).to eq({})
    end

    it 'does not touch updated_at or cache when the stored value is sent again' do
      described_class.new(user).apply(
        updates: { 'content_font_size' => 18, 'default_language' => 'zh-CN', 'default_sensitive' => false }
      )
      font = stored(user, 'content_font_size')
      language = stored(user, 'default_language')
      sensitive = stored(user, 'default_sensitive')
      [font, language, sensitive].each { |record| record.update_columns(updated_at: 2.hours.ago) }
      font_stamp = font.reload.updated_at
      language_stamp = language.reload.updated_at
      sensitive_stamp = sensitive.reload.updated_at
      expect(Rails.cache).not_to receive(:delete)

      result = described_class.new(user).apply(
        updates: { 'content_font_size' => 18, 'default_language' => 'zh-CN', 'default_sensitive' => false }
      )

      expect(result.unchanged_keys).to eq %w(content_font_size default_language default_sensitive)
      expect(result.changed_keys).to eq []
      expect(font.reload.updated_at).to eq font_stamp
      expect(language.reload.updated_at).to eq language_stamp
      expect(sensitive.reload.updated_at).to eq sensitive_stamp
      expect(language.value).to eq 'zh-CN'
      expect(sensitive.value).to be false
    end

    it 'replaces a stored float or numeric string with an integer of the same magnitude' do
      float_row = Setting.unscoped.new(thing_type: 'User', thing_id: user.id, var: 'content_font_size')
      float_row.value = 18.0
      float_row.save!
      string_row = Setting.unscoped.new(thing_type: 'User', thing_id: user.id, var: 'info_font_size')
      string_row.value = '18'
      string_row.save!

      result = described_class.new(user).apply(updates: { 'content_font_size' => 18, 'info_font_size' => 18 })

      expect(result.before['content_font_size']).to eq(state: :present, configured: 18.0)
      expect(result.before['info_font_size']).to eq(state: :present, configured: '18')
      expect(result.changed_keys).to eq %w(content_font_size info_font_size)
      expect(result.after['content_font_size']).to eq(state: :present, configured: 18)
      expect(result.after['info_font_size']).to eq(state: :present, configured: 18)
      expect(result.after['content_font_size'][:configured]).to be_a(Integer)
      expect(result.cache_deleted).to eq('content_font_size' => true, 'info_font_size' => true)
      expect(stored(user, 'content_font_size').value).to eq 18
      expect(stored(user, 'content_font_size').value).to be_a(Integer)
      expect(stored(user, 'info_font_size').value).to eq 18
      expect(stored(user, 'info_font_size').value).to be_a(Integer)

      font = stored(user, 'content_font_size')
      font.update_columns(updated_at: 2.hours.ago)
      stamp = font.reload.updated_at
      expect(Rails.cache).not_to receive(:delete)

      resend = described_class.new(user).apply(updates: { 'content_font_size' => 18 })

      expect(resend.unchanged_keys).to eq ['content_font_size']
      expect(resend.changed_keys).to eq []
      expect(resend.cache_deleted).to eq({})
      expect(font.reload.updated_at).to eq stamp
      expect(font.value).to be_a(Integer)
    end

    it 'leaves keys that were not in the request untouched' do
      user.settings['display_media'] = 'hide'

      described_class.new(user).apply(updates: { 'reduce_motion' => true }, resets: ['default_sensitive'])

      expect(user.settings['display_media']).to eq 'hide'
      expect(stored(user, 'reduce_motion').value).to be true
      expect(stored(user, 'default_sensitive')).to be_nil
    end

    it 'does not mutate the caller collections' do
      updates = { 'info_font_size' => 12 }.freeze
      resets = ['default_privacy'].freeze

      described_class.new(user).apply(updates: updates, resets: resets)

      expect(updates).to eq('info_font_size' => 12)
      expect(resets).to eq ['default_privacy']
    end

    it 'rolls back every key when a later save fails and does not delete cache' do
      writer = described_class.new(user)
      allow(writer).to receive(:insert_row).and_wrap_original do |method, user_id, key, value|
        raise 'second key failed' if key == 'reduce_motion'

        method.call(user_id, key, value)
      end
      expect(Rails.cache).not_to receive(:delete)

      expect do
        writer.apply(updates: { 'default_sensitive' => true, 'reduce_motion' => true })
      end.to raise_error(RuntimeError, 'second key failed')

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id)).to be_empty
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil
    end

    it 'makes the row visible to another connection before deleting cache' do
      seen = nil
      allow(Rails.cache).to receive(:delete).and_wrap_original do |method, key|
        other = ActiveRecord::Base.connection_pool.checkout
        begin
          seen = other.select_value(<<~SQL.squish)
            SELECT COUNT(*) FROM settings
            WHERE thing_type = 'User' AND thing_id = #{user.id.to_i} AND var = 'default_sensitive'
          SQL
        ensure
          ActiveRecord::Base.connection_pool.checkin(other)
        end
        method.call(key)
      end

      described_class.new(user).apply(updates: { 'default_sensitive' => true })

      expect(seen.to_i).to eq 1
      expect(stored(user, 'default_sensitive').value).to be true
    end

    it 'deletes cache only from committed!(should_run_callbacks: true)' do
      deletion = UserPreferences::CacheDeletion.new(user, ['default_sensitive'], revision: 1)
      expect(Rails.cache).not_to receive(:delete)

      deletion.before_committed!
      deletion.committed!(should_run_callbacks: false)
      deletion.rolledback!(force_restore_state: true, should_run_callbacks: true)
    end

    it 'retries a unique violation after rollback and then updates the committed row' do
      writer = described_class.new(user)
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

      expect(result.changed_keys).to eq ['default_sensitive']
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_sensitive').count).to eq 1
      expect(stored(user, 'default_sensitive').value).to be true
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
    end

    it 'raises Conflict after three unique violations and keeps no partial rows' do
      writer = described_class.new(user)
      allow(writer).to receive(:insert_row).and_wrap_original do |method, user_id, key, value|
        raise ActiveRecord::RecordNotUnique, 'duplicate key' if key == 'reduce_motion'

        method.call(user_id, key, value)
      end

      expect do
        writer.apply(updates: { 'default_sensitive' => true, 'reduce_motion' => true })
      end.to raise_error(UserPreferences::Conflict)

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id)).to be_empty
    end

    it 'does not retry an unexpected database error' do
      writer = described_class.new(user)
      calls = 0
      allow(writer).to receive(:insert_row).and_wrap_original do |_method, *_args|
        calls += 1
        raise ActiveRecord::StatementInvalid, 'bad sql'
      end

      expect { writer.apply(updates: { 'default_sensitive' => true }) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(calls).to eq 1
      expect(stored(user, 'default_sensitive')).to be_nil
    end

    it 'keeps the saved row when cache deletion fails twice and then succeeds' do
      calls = 0
      warnings = []
      allow(Rails.logger).to receive(:warn) { |line| warnings << line }
      allow(Rails.cache).to receive(:delete).and_wrap_original do |method, key|
        calls += 1
        raise StandardError, 'cache unavailable' if calls < 3

        method.call(key)
      end

      result = described_class.new(user).apply(updates: { 'default_language' => 'de' })

      expect(result.cache_deleted).to eq('default_language' => true)
      expect(stored(user, 'default_language').value).to eq 'de'
      matched = warnings.select { |line| line.include?('cache delete failed') && line.include?('var=default_language') }
      expect(matched.size).to eq 2
      expect(matched.join).not_to include('value=')
      expect(matched.join).to include('generation=legacy')
    end

    it 'records a cache deletion failure without raising after three errors' do
      warnings = []
      errors = []
      allow(Rails.logger).to receive(:warn) { |line| warnings << line }
      allow(Rails.logger).to receive(:error) { |line| errors << line }
      allow(Rails.cache).to receive(:delete).and_raise(StandardError, 'cache unavailable')

      result = described_class.new(user).apply(updates: { 'default_privacy' => 'private' })

      expect(result.cache_deleted).to eq('default_privacy' => false)
      expect(result.before_revision).to eq 0
      expect(result.after_revision).to eq 1
      expect(stored(user, 'default_privacy').value).to eq 'private'
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
      # Legacy and revision keys each retry on their own: two warnings and one error per key.
      expect(warnings.count { |line| line.include?('var=default_privacy') && line.include?('generation=legacy') }).to eq 2
      expect(warnings.count { |line| line.include?('var=default_privacy') && line.include?('generation=revision') }).to eq 2
      expect(errors.count { |line| line.include?('var=default_privacy') && line.include?('generation=legacy') && !line.include?('private') }).to eq 1
      expect(errors.count { |line| line.include?('var=default_privacy') && line.include?('generation=revision') && line.include?('revision=1') }).to eq 1
    end

    it 'does not treat a false cache delete as a confirmed deletion' do
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }
      allow(Rails.cache).to receive(:delete).and_return(false)

      result = described_class.new(user).apply(updates: { 'reduce_motion' => true })

      expect(result.cache_deleted).to eq('reduce_motion' => false)
      expect(stored(user, 'reduce_motion').value).to be true
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
      expect(errors.join).not_to include('cache delete failed')
    end

    it 'waits on the user row lock and keeps both keys' do
      release = Queue.new
      state = { started: false, finished: false }
      first = described_class.new(user)
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
          described_class.new(user).apply(updates: { 'reduce_motion' => true })
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
    end

    it 'lets the later writer win the same key' do
      release = Queue.new
      held = Queue.new
      first = described_class.new(user)
      allow(first).to receive(:lock_user).and_wrap_original do |method|
        locked = method.call
        held << true
        release.pop
        locked
      end
      first_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          first.apply(updates: { 'default_privacy' => 'public' })
        end
      end
      held.pop
      second_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.new(user).apply(updates: { 'default_privacy' => 'private' })
        end
      end
      sleep 0.2
      release << true
      first_thread.join
      second_thread.join

      expect(stored(user, 'default_privacy').value).to eq 'private'
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_privacy').count).to eq 1
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 2
    end

    it 'counts only committed writer changes' do
      other = nil
      expect(UserPreferences::Revision.current(user.id)).to eq 0
      expect(UserPreferenceRevision.find_by(user_id: user.id)).to be_nil

      first = described_class.new(user).apply(updates: { 'default_sensitive' => false })
      expect(first.before_revision).to eq 0
      expect(first.after_revision).to eq 1

      second = described_class.new(user).apply(
        updates: { 'default_sensitive' => true, 'reduce_motion' => true }
      )
      expect(second.before_revision).to eq 1
      expect(second.after_revision).to eq 2
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 2

      same = described_class.new(user).apply(updates: { 'default_sensitive' => true })
      expect(same.before_revision).to eq 2
      expect(same.after_revision).to eq 2

      nil_row = Setting.unscoped.new(thing_type: 'User', thing_id: user.id, var: 'content_font_size')
      nil_row.value = nil
      nil_row.save!
      removed = described_class.new(user).apply(resets: ['content_font_size'])
      expect(removed.after_revision).to eq 3

      absent = described_class.new(user).apply(resets: ['content_font_size'])
      expect(absent.before_revision).to eq 3
      expect(absent.after_revision).to eq 3

      expect { described_class.new(user).apply(updates: { 'default_language' => 'ja-JP' }) }
        .to raise_error(UserPreferences::InvalidInput)
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 3

      expect(described_class.new(user).apply.after_revision).to eq 3
      expect(described_class.new(user).apply(resets: []).after_revision).to eq 3

      other = Fabricate(:user)
      other_result = described_class.new(other).apply(updates: { 'reduce_motion' => true })
      expect(other_result.after_revision).to eq 1
      expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 3
    ensure
      if other&.id
        Setting.unscoped.where(thing_type: 'User', thing_id: other.id).delete_all
        UserPreferenceRevision.where(user_id: other.id).delete_all
        User.where(id: other.id).delete_all
        Account.where(id: other.account_id).delete_all
      end
    end
  end
end
