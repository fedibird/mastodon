# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'credentials legacy writer' do
  self.use_transactional_tests = false

  def stored(user, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  def revision(user)
    UserPreferences::Revision.current(user.id)
  end

  def legacy_key(user, var)
    Setting.cache_key(var, user)
  end

  def discard_user(user)
    return unless user&.id

    account_id = user.account_id
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    UserPreferenceRevision.where(user_id: user.id).delete_all
    MediaAttachment.where(account_id: account_id).delete_all if account_id
    Account.where(id: account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def discard_account(account)
    return unless account&.id

    User.where(account_id: account.id).find_each { |owner| discard_user(owner) }
    MediaAttachment.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
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

  def setting_cycles(events, keys)
    relevant = events.select do |event|
      (keys.include?(event[:key]) && %w(rewrite_cache cache_deletion).include?(event[:source])) ||
        %w(commit notify activitypub).include?(event[:op])
    end
    relevant.each_with_index.with_object([]) do |(event, index), kept|
      if event[:op] == 'commit'
        nxt = relevant[index + 1]
        kept << event if nxt && nxt[:op] == 'write' && nxt[:source] == 'rewrite_cache'
      else
        kept << event
      end
    end
  end

  describe Api::V1::Accounts::CredentialsController, type: :controller do
    let(:user) { Fabricate(:user) }
    let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:accounts') }

    before do
      allow(controller).to receive(:doorkeeper_token) { token }
      allow(VerifyAccountLinksWorker).to receive(:perform_async)
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
      allow(AuthorizeFollowWorker).to receive(:push_bulk)
    end

    after { discard_user(user) }

    describe 'basic saves' do
      it 'stores privacy alone and fills the omitted sensitive default' do
        patch :update, params: { source: { privacy: 'unlisted' } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq 'unlisted'
        expect(stored(user, 'default_sensitive').value).to be false
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'preferred_posting_language')).to be_nil
        expect(revision(user)).to eq 2
        expect(body_as_json[:source][:privacy]).to eq 'unlisted'
        expect(body_as_json[:source][:sensitive]).to be false
      end

      it 'materializes omitted privacy and sensitive when only language is sent' do
        events = nil
        messages = nil
        observe do |seen, published|
          allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) { seen << { op: 'activitypub' } }
          patch :update, params: { source: { language: 'de' } }, as: :json
          events = seen
          messages = published
        end

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq 'public'
        expect(stored(user, 'default_language').value).to eq 'de'
        expect(stored(user, 'default_sensitive').value).to be false
        expect(stored(user, 'preferred_posting_language')).to be_nil
        expect(revision(user)).to eq 3
        expect(body_as_json[:source]).to include(privacy: 'public', language: 'de', sensitive: false)

        privacy = legacy_key(user, 'default_privacy')
        language = legacy_key(user, 'default_language')
        sensitive = legacy_key(user, 'default_sensitive')
        cycles = setting_cycles(events, [privacy, language, sensitive])
        expect(cycles.map { |event| event[:op] }).to eq(
          %w(commit write delete notify commit write delete notify commit write delete notify activitypub)
        ), events.inspect
        expect(cycles[1]).to include(key: privacy, source: 'rewrite_cache', value: 'public', after_sql_commit: true)
        expect(cycles[2]).to include(key: privacy, source: 'cache_deletion', after_sql_commit: true)
        expect(cycles[5]).to include(key: language, source: 'rewrite_cache', value: 'de', after_sql_commit: true)
        expect(cycles[9]).to include(key: sensitive, source: 'rewrite_cache', value: false, after_sql_commit: true)
        expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'changed_keys') }).to eq(
          [['user.default_privacy'], ['user.default_language'], ['user.default_sensitive']]
        )
        expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'revision') }).to eq %w(1 2 3)
        expect(Rails.cache.exist?(privacy)).to be false
        expect(Rails.cache.exist?(language)).to be false
        expect(Rails.cache.exist?(sensitive)).to be false
      end

      it 'stores an explicit sensitive value' do
        patch :update, params: { source: { sensitive: true } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_sensitive').value).to be true
        expect(body_as_json[:source][:sensitive]).to be true
        expect(revision(user)).to eq 2
      end
    end

    describe 'scalar compatibility' do
      it 'stores direct, an empty privacy string, and a regional language' do
        patch :update, params: { source: { privacy: 'direct', language: 'ja-JP' } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq 'direct'
        expect(stored(user, 'default_language').value).to eq 'ja-JP'
        expect(stored(user, 'preferred_posting_language')).to be_nil
        expect(user.reload.preferred_posting_language).not_to eq 'ja-JP'
        expect(body_as_json[:source][:privacy]).to eq 'direct'
        expect(body_as_json[:source][:language]).to eq 'ja-JP'
      end

      it 'stores an empty privacy string' do
        patch :update, params: { source: { privacy: '' } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq ''
        expect(user.reload.setting_default_privacy).to eq ''
      end

      it 'casts sensitive strings and stores a blank sensitive value as a nil row' do
        patch :update, params: { source: { privacy: 'unlisted', language: 'en', sensitive: '0' } }, as: :json
        expect(stored(user, 'default_sensitive').value).to be false

        patch :update, params: { source: { privacy: 'unlisted', language: 'en', sensitive: '1' } }, as: :json
        expect(stored(user, 'default_sensitive').value).to be true

        before = revision(user)
        patch :update, params: { source: { privacy: 'unlisted', language: 'en', sensitive: '' } }, as: :json

        expect(response).to have_http_status(200)
        sensitive = stored(user, 'default_sensitive')
        expect(sensitive).to be_present
        expect(sensitive.value).to be_nil
        expect(revision(user)).to eq before + 1
      end

      it 'skips an explicit null and still stores an omitted sensitive default' do
        user.settings['default_privacy'] = 'direct'
        privacy = stored(user, 'default_privacy')
        privacy.update_columns(updated_at: 3.hours.ago)
        stamp = privacy.reload.updated_at

        patch :update, params: { source: { privacy: nil } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq 'direct'
        expect(privacy.reload.updated_at).to eq stamp
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'default_sensitive').value).to be false
        expect(revision(user)).to eq 1
      end

      it 'fills privacy from the getter after the account update' do
        user.account.update!(locked: true)

        patch :update, params: { locked: false, source: { language: 'de' } }, as: :json

        expect(response).to have_http_status(200)
        expect(user.account.reload.locked).to be false
        expect(stored(user, 'default_privacy').value).to eq 'public'
        expect(stored(user, 'default_language').value).to eq 'de'
        expect(stored(user, 'default_sensitive').value).to be false
        expect(revision(user)).to eq 3
      end

      it 'does not save settings for a missing source or an empty source, and still distributes' do
        patch :update, params: { display_name: 'Named' }, as: :json

        expect(response).to have_http_status(200)
        expect(user.account.reload.display_name).to eq 'Named'
        expect(stored(user, 'default_privacy')).to be_nil
        expect(revision(user)).to eq 0
        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(user.account.id)

        patch :update, params: { source: {} }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy')).to be_nil
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(stored(user, 'default_language')).to be_nil
        expect(revision(user)).to eq 0
        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).twice
      end

      it 'does not move revision or cache when the same source values are sent again' do
        user.settings['default_privacy'] = 'unlisted'
        user.settings['default_sensitive'] = false
        user.settings['default_language'] = 'de'
        %w(default_privacy default_sensitive default_language).each do |key|
          stored(user, key).update_columns(updated_at: 3.hours.ago)
        end
        stamps = %w(default_privacy default_sensitive default_language).index_with { |key| stored(user, key).reload.updated_at }
        privacy_key = legacy_key(user, 'default_privacy')
        Rails.cache.write(privacy_key, 'sentinel')

        events = nil
        messages = nil
        observe do |seen, published|
          patch :update, params: { source: { privacy: 'unlisted', sensitive: false, language: 'de' } }, as: :json
          events = seen
          messages = published
        end

        expect(response).to have_http_status(200)
        expect(revision(user)).to eq 0
        stamps.each { |key, stamp| expect(stored(user, key).reload.updated_at).to eq stamp }
        expect(Rails.cache.read(privacy_key)).to eq 'sentinel'
        expect(events.select { |event| event[:key] == privacy_key || event[:op] == 'notify' }).to eq []
        expect(messages).to eq []
        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(user.account.id)
      end
    end

    describe 'non-scalar rejection' do
      it 'rejects a privacy object without storing it' do
        patch :update, params: {
          display_name: 'Opened',
          source: { privacy: { bad: 'direct' } },
        }, as: :json

        expect(response).to have_http_status(422)
        expect(body_as_json).to eq(
          error: 'Invalid source preferences',
          errors: [{ key: 'source.privacy', code: 'invalid_type' }]
        )
        expect(response.body).not_to include('bad')
        expect(response.body).not_to include(token.token)
        expect(stored(user, 'default_privacy')).to be_nil
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(revision(user)).to eq 0
        expect(user.account.reload.display_name).to eq 'Opened'
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end

      it 'rejects a language array after the filled privacy save' do
        messages = []
        observe do |_seen, published|
          messages = published
          patch :update, params: { source: { privacy: 'unlisted', language: ['ja-JP'], sensitive: true } }, as: :json
        end

        expect(response).to have_http_status(422)
        expect(body_as_json[:errors]).to eq [{ key: 'source.language', code: 'invalid_type' }]
        expect(response.body).not_to include('ja-JP')
        expect(stored(user, 'default_privacy').value).to eq 'unlisted'
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(revision(user)).to eq 1
        expect(messages.map { |message| JSON.parse(message.last).dig('payload', 'changed_keys') }).to eq [['user.default_privacy']]
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end

      it 'rejects a non-scalar sensitive value after earlier keys commit' do
        patch :update, params: { source: { privacy: 'unlisted', language: 'de', sensitive: ['1'] } }, as: :json

        expect(response).to have_http_status(422)
        expect(body_as_json[:errors]).to eq [{ key: 'source.sensitive', code: 'invalid_type' }]
        expect(stored(user, 'default_privacy').value).to eq 'unlisted'
        expect(stored(user, 'default_language').value).to eq 'de'
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(revision(user)).to eq 2
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end

      it 'keeps the account update and the earlier key when a later value is invalid' do
        user.account.update!(locked: true)
        follower = Fabricate(:account)
        Fabricate(:follow_request, account: follower, target_account: user.account)
        captured = nil
        allow(AuthorizeFollowWorker).to receive(:push_bulk) do |requests, &block|
          captured = requests.map { |request| block.call(request) }
        end

        patch :update, params: {
          display_name: 'Opened',
          locked: false,
          source: { language: ['ja-JP'] },
        }, as: :json

        expect(response).to have_http_status(422)
        expect(user.account.reload.display_name).to eq 'Opened'
        expect(user.account.reload.locked).to be false
        expect(stored(user, 'default_privacy').value).to eq 'public'
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(revision(user)).to eq 1
        expect(captured).to eq [[follower.id, user.account.id]]
        expect(VerifyAccountLinksWorker).to have_received(:perform_async).with(user.account.id)
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      ensure
        discard_account(follower)
      end

      it 'does not turn a database error into the source 422 response' do
        allow_any_instance_of(UserPreferences::LegacyWriter).to receive(:update).and_wrap_original do |method, key, value|
          raise ActiveRecord::StatementInvalid, 'db down' if key == 'default_language'

          method.call(key, value)
        end

        expect do
          patch :update, params: {
            display_name: 'Opened',
            source: { privacy: 'unlisted', language: 'de', sensitive: true },
          }, as: :json
        end.to raise_error(ActiveRecord::StatementInvalid)

        expect(user.account.reload.display_name).to eq 'Opened'
        expect(stored(user, 'default_privacy').value).to eq 'unlisted'
        expect(stored(user, 'default_language')).to be_nil
        expect(stored(user, 'default_sensitive')).to be_nil
        expect(revision(user)).to eq 1
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end

      it 'does not turn OpenTransaction into the source 422 response' do
        allow_any_instance_of(UserPreferences::LegacyWriter).to receive(:update).and_raise(UserPreferences::OpenTransaction)

        expect do
          patch :update, params: { display_name: 'Opened', source: { privacy: 'unlisted' } }, as: :json
        end.to raise_error(UserPreferences::OpenTransaction)

        expect(user.account.reload.display_name).to eq 'Opened'
        expect(stored(user, 'default_privacy')).to be_nil
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end
    end

    describe 'account side effects' do
      it 'approves follow requests and distributes only after the settings save' do
        user.account.update!(locked: true)
        follower = Fabricate(:account)
        Fabricate(:follow_request, account: follower, target_account: user.account)
        order = []
        allow(AuthorizeFollowWorker).to receive(:push_bulk) { order << :authorize }
        allow(VerifyAccountLinksWorker).to receive(:perform_async) { order << :verify }
        allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) do
          order << [:activitypub, revision(user)]
        end

        patch :update, params: { locked: false, source: { privacy: 'public', language: 'de', sensitive: true } }, as: :json

        expect(response).to have_http_status(200)
        expect(order).to eq [:authorize, :verify, [:activitypub, 3]]
        expect(revision(user)).to eq 3
      ensure
        discard_account(follower)
      end

      it 'distributes when source is absent and when every source value is unchanged' do
        user.settings['default_privacy'] = 'unlisted'
        user.settings['default_sensitive'] = false
        user.settings['default_language'] = 'de'

        patch :update, params: { display_name: 'Still' }, as: :json
        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(user.account.id)

        patch :update, params: { source: { privacy: 'unlisted', sensitive: false, language: 'de' } }, as: :json

        expect(response).to have_http_status(200)
        expect(revision(user)).to eq 0
        expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).twice
      end
    end

    describe 'oauth scopes' do
      it 'saves source with the write scope' do
        access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write')
        allow(controller).to receive(:doorkeeper_token) { access_token }

        patch :update, params: { source: { language: 'de' } }, as: :json

        expect(response).to have_http_status(200)
        expect(access_token.scopes.to_s).not_to include('write:preferences')
        expect(stored(user, 'default_language').value).to eq 'de'
        expect(revision(user)).to eq 3
      end

      it 'saves source with write:accounts' do
        patch :update, params: { source: { privacy: 'unlisted' } }, as: :json

        expect(response).to have_http_status(200)
        expect(stored(user, 'default_privacy').value).to eq 'unlisted'
        expect(revision(user)).to eq 2
      end

      it 'rejects a token whose only scope is write:preferences' do
        access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences')
        allow(controller).to receive(:doorkeeper_token) { access_token }

        patch :update, params: { display_name: 'Nope', source: { language: 'de' } }, as: :json

        expect(response).to have_http_status(403)
        expect(user.account.reload.display_name).not_to eq 'Nope'
        expect(stored(user, 'default_language')).to be_nil
        expect(revision(user)).to eq 0
        expect(ActivityPub::UpdateDistributionWorker).not_to have_received(:perform_async)
      end

      it 'rejects a missing token before any write' do
        allow(controller).to receive(:doorkeeper_token) { nil }

        patch :update, params: { display_name: 'Nope', source: { language: 'de' } }, as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(user.account.reload.display_name).not_to eq 'Nope'
        expect(stored(user, 'default_language')).to be_nil
        expect(revision(user)).to eq 0
      end
    end
  end
end
