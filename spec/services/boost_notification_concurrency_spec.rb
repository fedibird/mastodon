# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Concurrent boost notification delivery', type: :service do
  self.use_transactional_tests = false

  before do
    @cache = Rails.cache
    ActiveRecord::Base.connection_pool.lock_thread = false
    @recipient = Fabricate(:user).account
    @booster = Fabricate(:user).account
    @recipient.follow!(@booster, notify_reblogs: true)
    @original = Fabricate(:status, account: @booster)
    @boost = Fabricate(:status, account: @booster, reblog: @original)
    Fabricate(:web_push_subscription, user: @recipient.user, data: { alerts: { status: true } })
    allow(Web::PushNotificationWorker).to receive(:push_bulk)
  end

  after do
    @boost&.destroy!
    @original&.destroy!
    @recipient&.destroy!
    @booster&.reload&.destroy!
    Rails.cache = @cache
    ActiveRecord::Base.connection_pool.lock_thread = true
  end

  it 'invalidates cached relationship values after a committed change' do
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    expect(AccountRelationshipsPresenter.new([@booster.id], @recipient.id).notifying_reblogs[@booster.id]).to be true
    @recipient.active_relationships.find_by!(target_account: @booster).update!(notify_reblogs: false)
    expect(AccountRelationshipsPresenter.new([@booster.id], @recipient.id).notifying_reblogs[@booster.id]).to be_falsey
  end

  it 'serializes overlapping PostgreSQL transactions and only pushes the winner' do
    entered = Queue.new
    release = Queue.new
    started = Queue.new
    first = true
    mutex = Mutex.new
    allow_any_instance_of(Notification).to receive(:save!).and_wrap_original do |method, *args|
      hold = mutex.synchronize do
        was_first = first
        first = false
        was_first
      end
      if hold
        entered << true
        Timeout.timeout(10) { release.pop }
      end
      method.call(*args)
    end
    threads = []
    begin
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          NotifyService.new.call(Account.find(@recipient.id), :status, Status.find(@boost.id))
        end
      end
      Timeout.timeout(10) { entered.pop }
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          started << true
          NotifyService.new.call(Account.find(@recipient.id), :status, Status.find(@boost.id))
        end
      end
      Timeout.timeout(10) { started.pop }
      # Wait for a real waiter on the transaction lock, not just a scheduled thread.
      Timeout.timeout(10) do
        loop do
          break if ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted").to_i.positive?
          sleep 0.01
        end
      end
      release << true
      threads.each { |thread| expect(thread.join(10)).to be_present; thread.value }
      # A later worker retry must not push again either.
      LocalNotificationWorker.new.perform(@recipient.id, @boost.id, 'Status', 'status')
      expect(Notification.where(account: @recipient, activity: @boost, type: :status).count).to eq 1
      expect(Web::PushNotificationWorker).to have_received(:push_bulk).once
    ensure
      release << true
      threads.each { |thread| thread.join(10) }
    end
  end
end
