# frozen_string_literal: true

require 'rails_helper'

describe 'AT Protocol refresh concurrency', type: :model do
  # Row locks only block other connections. The example transaction would hide
  # the identity from those connections, so this example commits.
  self.use_transactional_tests = false

  it 'exchanges a rotating refresh token once' do
    user = Fabricate(:user)
    posts = []
    mutex = Mutex.new
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      world.bodies[:token_handler] = lambda do |request|
        fields = Rack::Utils.parse_nested_query(request.body)
        if fields['grant_type'] == 'refresh_token'
          mutex.synchronize { posts << fields['refresh_token'] }
          sleep 0.3
          atproto_json(atproto_tokens(refresh: 'refresh-rotated-once-SENTINEL', expires_in: 600))
        else
          atproto_json(atproto_tokens(refresh: 'refresh-initial-concurrent', expires_in: 120))
        end
      end
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      travel 5.minutes
      errors = Queue.new
      threads = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ExternalBridge::Atproto::Refresh.call(user: User.find(user.id), identity_id: identity.id, dns: world.dns)
          end
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)
      expect(errors.size).to eq(0)
      expect(posts.size).to eq(1)
      expect(posts.first).to eq('refresh-initial-concurrent')
      expect(identity.reload.refresh_generation).to eq(1)
    end
  ensure
    travel_back
    Setting.external_bridge_atproto = false
    Setting.external_bridge_atproto_testers = ''
    Rails.cache.clear
    if user
      ExternalOauthAttempt.where(user_id: user.id).delete_all
      ExternalIdentity.where(user_id: user.id).delete_all
      UserExternalCredential.where(user_id: user.id).delete_all
      account = user.account
      user.destroy
      account&.destroy
    end
  end
end
