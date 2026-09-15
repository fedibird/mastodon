# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe FollowImport::DispatchLease do
  def create_batch
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def advisory_lock_held_on_current_session?
    sql = <<~SQL.squish
      SELECT EXISTS (
        SELECT 1 FROM pg_locks
        WHERE locktype = 'advisory'
          AND classid = #{described_class::LOCK_NAMESPACE}
          AND objid = #{described_class::LOCK_KEY}
          AND objsubid = 1
          AND granted
          AND pid = pg_backend_pid()
      )
    SQL
    ActiveModel::Type::Boolean.new.cast(ActiveRecord::Base.connection.select_value(sql))
  end

  describe 'lock identity' do
    it 'uses a documented two-integer key that does not come from String#hash' do
      expect(described_class::LOCK_NAMESPACE).to eq 0x4649
      expect(described_class::LOCK_KEY).to eq 1
      expect(described_class::TRY_LOCK_SQL).to eq "SELECT pg_try_advisory_lock(#{0x4649}, 1)"
      expect(described_class::UNLOCK_SQL).to eq "SELECT pg_advisory_unlock(#{0x4649}, 1)"
      expect(described_class::TRY_LOCK_SQL).not_to include('xact')
      expect(described_class::UNLOCK_SQL).not_to include('xact')
    end
  end

  describe 'connection checkout semantics' do
    let(:connection) { double('lease-connection') }
    let(:pool) { double('connection-pool') }

    before do
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool)
      allow(pool).to receive(:with_connection).and_yield(connection)
      allow(pool).to receive(:checkout)
      allow(pool).to receive(:checkin)
      allow(pool).to receive(:remove)
    end

    it 'yields the body on a successful pg_try_advisory_lock and unlocks the same connection' do
      sqls = []
      allow(connection).to receive(:select_value) do |sql|
        sqls << sql
        true
      end

      yielded = false
      result = described_class.with_lease { yielded = true; :body }

      expect(yielded).to be true
      expect(result).to eq :body
      expect(sqls).to eq [described_class::TRY_LOCK_SQL, described_class::UNLOCK_SQL]
      expect(pool).to have_received(:with_connection).once
      expect(pool).not_to have_received(:checkout)
      expect(pool).not_to have_received(:checkin)
    end

    it 'does not yield when pg_try_advisory_lock fails' do
      allow(connection).to receive(:select_value).and_return(false)

      yielded = false
      result = described_class.with_lease { yielded = true }

      expect(yielded).to be false
      expect(result).to eq described_class::BUSY
      expect(connection).to have_received(:select_value).with(described_class::TRY_LOCK_SQL)
      expect(connection).not_to have_received(:select_value).with(described_class::UNLOCK_SQL)
      expect(pool).not_to have_received(:checkin)
    end

    it 'unlocks the same checked-out connection when the body raises' do
      sqls = []
      allow(connection).to receive(:select_value) do |sql|
        sqls << sql
        true
      end

      expect { described_class.with_lease { raise StandardError, 'tick exploded' } }
        .to raise_error(StandardError, 'tick exploded')

      expect(sqls).to eq [described_class::TRY_LOCK_SQL, described_class::UNLOCK_SQL]
      expect(pool).not_to have_received(:checkin)
    end

    it 'does not use a transaction-level advisory lock' do
      sqls = []
      allow(connection).to receive(:select_value) do |sql|
        sqls << sql.to_s
        true
      end
      allow(connection).to receive(:transaction)

      described_class.with_lease { true }

      expect(sqls.join).to include('pg_try_advisory_lock')
      expect(sqls.join).to include('pg_advisory_unlock')
      expect(sqls.join).not_to include('pg_try_advisory_xact_lock')
      expect(sqls.join).not_to include('pg_advisory_xact_lock')
      expect(connection).not_to have_received(:transaction)
    end

    it 'disconnects and removes a live connection when unlock cannot be confirmed' do
      allow(connection).to receive(:select_value).with(described_class::TRY_LOCK_SQL).and_return(true)
      allow(connection).to receive(:select_value).with(described_class::UNLOCK_SQL).and_return(false)
      allow(connection).to receive(:disconnect!)

      described_class.with_lease { true }

      expect(connection).to have_received(:disconnect!)
      expect(pool).to have_received(:remove).with(connection)
      expect(pool).not_to have_received(:checkin)
    end
  end

  describe 'one connection per tick' do
    it 'runs ActiveRecord work on the same PostgreSQL session that holds the lease' do
      ActiveRecord::Base.connection
      held_during_body = nil

      described_class.with_lease do
        FollowImportTarget.where(state: :pending).count
        FollowImportDispatchTickObservation.create!(
          observed_at: Time.now.utc,
          tick_id: 'lease-same-session',
          scheduler_mode: 'shadow',
          lease_acquired: true,
          outcome: 'shadow_observed',
          claimed_count: 0,
          metadata: {},
          created_at: Time.now.utc
        )
        held_during_body = advisory_lock_held_on_current_session?
      end

      expect(held_during_body).to be true
      expect(advisory_lock_held_on_current_session?).to be false
    end

    it 'does not check out a second pool connection for ActiveRecord work while holding the lease' do
      pool = ActiveRecord::Base.connection_pool
      thread_connection = ActiveRecord::Base.connection
      checkouts = 0

      allow(pool).to receive(:checkout).and_wrap_original do |original, *args|
        checkouts += 1
        original.call(*args)
      end

      described_class.with_lease do
        expect(ActiveRecord::Base.connection.object_id).to eq(thread_connection.object_id)
        FollowImportTarget.where(state: :pending).count
        FollowImportDispatchTickObservation.create!(
          observed_at: Time.now.utc,
          tick_id: 'lease-no-second-checkout',
          scheduler_mode: 'shadow',
          lease_acquired: true,
          outcome: 'shadow_observed',
          claimed_count: 0,
          metadata: {},
          created_at: Time.now.utc
        )
      end

      expect(checkouts).to eq 0
    end
  end

  describe 'PostgreSQL session exclusion' do
    it 'does not allow two checked-out connections to both enter the critical section' do
      ready = Queue.new
      release = Queue.new
      second_status = Queue.new
      first_entered = false
      holder = nil
      waiter = nil

      holder = Thread.new do
        described_class.with_lease do
          first_entered = true
          ready << true
          release.pop
          :held
        end
      end

      Timeout.timeout(5) do
        ready.pop
        expect(first_entered).to be true

        waiter = Thread.new do
          second_status << described_class.with_lease { :should_not_run }
        end

        expect(second_status.pop).to eq described_class::BUSY
      end
    ensure
      release << true
      holder&.join(2)
      waiter&.join(2)
    end

    it 'does not mutate Follow Import rows when the lease is lost or held' do
      batch = create_batch
      target = batch.targets.create!(target_key_hash: 'lease-spec', position: 0)
      before = target.attributes.slice('state', 'queued_at', 'updated_at')

      described_class.with_lease do
        expect(target.reload.attributes.slice('state', 'queued_at')).to eq('state' => 'pending', 'queued_at' => nil)
      end

      busy_sql = described_class.with_lease { :inside }
      expect(busy_sql).to eq :inside

      target.reload
      expect(target.state).to eq 'pending'
      expect(target.queued_at).to eq before['queued_at']
    end
  end
end
